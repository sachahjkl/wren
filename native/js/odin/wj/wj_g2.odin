// wj_g2.odin: the extra wj helpers the G2 domains (net, streams, files, URL, simple storage) need, on top of wj.odin.
//
// The spike's wj.odin covers the handful of symbols web_strategy.odin used. The G2 domains touch far more of the engine
// and of runtime/web.h: string conversions, buffer sources, typed arrays, iterators, promises of the browser, events,
// errors as values, and the `wr_*` imports of the browser modules this group speaks to (storage, crypto, url,
// encoding...). Rather than edit the shared wj.odin (owned by the spike), G2 adds them here, in the same `wj` package,
// keeping names and signatures matched to the C so a ported domain reads like the C it replaces.
//
// The split by kind is the same as wj.odin:
//   * real symbols (quickjs.h JS_EXTERN, and the wj_*/web_* of engine/runtime) -> `foreign` blocks;
//   * `static inline`/macros of the headers (JS_NewStringLen's inline friends, JS_PROP_C_W_E, the NAN-box predicates)
//     -> reimplemented inline here;
//   * fields of global C structs (wj_obj.handle/impl, wj_the_realm.protos) -> the tiny C accessors of wj_g2_shim.c.
package wj

// ---- QuickJS value handling (quickjs.h JS_EXTERN; names/signatures must match C) ----

@(default_calling_convention = "c")
foreign {
	JS_ToBool          :: proc(ctx: ^Context, v: JSValue) -> i32 ---          // -1 on exception
	JS_ToString        :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	JS_NewStringLen    :: proc(ctx: ^Context, str: [^]u8, len: uint) -> JSValue ---
	JS_NewUint8ArrayCopy :: proc(ctx: ^Context, buf: [^]u8, len: uint) -> JSValue ---
	JS_NewArray        :: proc(ctx: ^Context) -> JSValue ---
	JS_NewObject       :: proc(ctx: ^Context) -> JSValue ---
	JS_SetPropertyStr  :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue) -> i32 ---
	JS_DefinePropertyValueUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue, flags: i32) -> i32 ---
	JS_GetTypedArrayType :: proc(v: JSValue) -> i32 ---                        // JSTypedArrayEnum or -1
	JS_IsArray         :: proc(v: JSValue) -> bool ---
	JS_NewAtom         :: proc(ctx: ^Context, str: cstring) -> u32 ---
	JS_FreeAtom        :: proc(ctx: ^Context, atom: u32) ---
	JS_DeleteProperty  :: proc(ctx: ^Context, obj: JSValue, atom: u32, flags: i32) -> i32 ---
	JS_ThrowRangeError :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	JS_DefinePropertyValueStr :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue, flags: i32) -> i32 ---
	JS_Throw           :: proc(ctx: ^Context, obj: JSValue) -> JSValue ---
	JS_GetException    :: proc(ctx: ^Context) -> JSValue ---
	JS_HasException    :: proc(ctx: ^Context) -> bool ---
	JS_GetLength       :: proc(ctx: ^Context, obj: JSValue, pres: ^i64) -> i32 ---
	JS_GetPropertyUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32) -> JSValue ---
}

// JSTypedArrayEnum (quickjs.h). getRandomValues accepts the integer ones; encodeInto wants UINT8.
Typed_Array :: enum i32 {
	Uint8C    = 0,
	Int8      = 1,
	Uint8     = 2,
	Int16     = 3,
	Uint16    = 4,
	Int32     = 5,
	Uint32    = 6,
	Big_Int64 = 7,
	Big_Uint64 = 8,
	Float16   = 9,
	Float32   = 10,
	Float64   = 11,
}

PROP_C_W_E :: i32(7)   // JS_PROP_CONFIGURABLE | WRITABLE | ENUMERABLE

// quickjs.h inline predicates / constructors reimplemented on the NAN box (wj.odin has the hot ones; these are the
// rest the G2 domains use).
new_uint32 :: #force_inline proc "contextless" (v: u32) -> JSValue {
	return v <= 0x7FFF_FFFF ? new_int32(i32(v)) : UNDEFINED   // caller uses new_number for the >I32_MAX case
}
is_null_or_undefined :: #force_inline proc "contextless" (v: JSValue) -> bool { return is_null(v) || is_undefined(v) }
is_array_val :: #force_inline proc "contextless" (v: JSValue) -> bool { return JS_IsArray(v) }

// A JS string from UTF-8 bytes (JS_NewStringLen). Odin strings and []u8 both decay to (ptr, len).
new_string_len :: #force_inline proc "contextless" (ctx: ^Context, s: []u8) -> JSValue {
	return JS_NewStringLen(ctx, raw_data(s), uint(len(s)))
}
new_string :: #force_inline proc "contextless" (ctx: ^Context, s: string) -> JSValue {
	return JS_NewStringLen(ctx, raw_data(s), uint(len(s)))
}
new_cstring :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(s)), uint(len(s)))
}
new_uint8_array :: #force_inline proc "contextless" (ctx: ^Context, s: []u8) -> JSValue {
	return JS_NewUint8ArrayCopy(ctx, raw_data(s), uint(len(s)))
}
to_bool :: #force_inline proc "contextless" (ctx: ^Context, v: JSValue) -> bool { return JS_ToBool(ctx, v) != 0 }

// wj_array_set (qjs_backend.h is a `static inline`): a data property, never [[Set]] (an indexed setter on a prototype
// must not run). -1 throws.
array_set :: #force_inline proc "contextless" (ctx: ^Context, arr: JSValue, i: u32, v: JSValue) -> i32 {
	return JS_DefinePropertyValueUint32(ctx, arr, i, v, PROP_C_W_E)
}

typed_array_type :: #force_inline proc "contextless" (v: JSValue) -> i32 { return JS_GetTypedArrayType(v) }

// JS_VALUE_GET_INT (quickjs.h macro, NAN boxing): the low 32 bits of an int-tagged value. Used where the glue stashes a
// small integer in a JSValue slot (web_url's pair collector).
value_get_int :: #force_inline proc "contextless" (v: JSValue) -> i32 { return i32(u32(v)) }

// ---- wj.h: errors, strings, conversions, objects (real symbols) ----

@(default_calling_convention = "c")
foreign {
	// errors
	wj_throw_type       :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_range      :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_dom        :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	wj_throw_status     :: proc(ctx: ^Context, status: i32, what: cstring) -> JSValue ---
	wj_throw_arity      :: proc(ctx: ^Context, what: cstring, required: i32, given: i32) -> JSValue ---
	wj_throw_unsupported :: proc(ctx: ^Context, iface: cstring, member: cstring) -> JSValue ---

	// platform objects
	wj_this         :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr --- // ^wj_obj or nil (+ TypeError)
	wj_unwrap       :: proc(v: JSValue, iface: i32) -> rawptr ---                        // ^wj_obj or nil (no throw)
	wj_wrap_node    :: proc(ctx: ^Context, node: u64) -> JSValue ---
	wj_wrap_host    :: proc(ctx: ^Context, handle: u64, iface: i32) -> JSValue ---
	wj_cached       :: proc(ctx: ^Context, handle: u64) -> JSValue ---
	wj_wrap_owned   :: proc(ctx: ^Context, handle: u64, iface: i32, new_target: JSValue) -> JSValue ---
	wj_new_object_for :: proc(ctx: ^Context, iface: i32, new_target: JSValue, impl: rawptr, impl_free: proc "c" (p: rawptr)) -> JSValue ---

	// strings: scratch buffer of browser string results
	wj_scratch_grow :: proc(need: u32) -> bool ---

	// Web IDL conversions (false + exception pending on a throw)
	wj_to_str    :: proc(ctx: ^Context, v: JSValue, out: ^Str, flags: i32, def: cstring) -> bool ---
	wj_str_free  :: proc(ctx: ^Context, s: ^Str) ---
	wj_to_int32  :: proc(ctx: ^Context, v: JSValue, out: ^i32, bits: i32, mode: i32) -> bool ---
	wj_to_uint32 :: proc(ctx: ^Context, v: JSValue, out: ^u32, bits: i32, mode: i32) -> bool ---
	wj_to_int64  :: proc(ctx: ^Context, v: JSValue, out: ^i64, mode: i32) -> bool ---
	wj_to_uint64 :: proc(ctx: ^Context, v: JSValue, out: ^u64, mode: i32) -> bool ---
	wj_to_double :: proc(ctx: ^Context, v: JSValue, out: ^f64, restricted: bool) -> bool ---
	wj_check_enum :: proc(ctx: ^Context, s: ^Str, values: [^]cstring, type: cstring) -> bool ---
	wj_enum_index :: proc(s: ^Str, values: [^]cstring) -> i32 ---
	wj_to_handle :: proc(ctx: ^Context, v: JSValue, iface: i32, nullable: bool, out: ^u64, message: cstring) -> bool ---

	// events, promises
	wj_event_construct :: proc(ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue, iface: i32, name: cstring) -> JSValue ---
	wj_promise_from_host :: proc(ctx: ^Context, host: u64, kind: i32, settle: Host_Settle, data: JSValue) -> JSValue ---
	wj_promise_reject_pending :: proc(ctx: ^Context) -> JSValue ---
	wj_report_exception :: proc(ctx: ^Context, exc: JSValue) ---
}

// wj_str: a UTF-8 view of a converted string (owned when `owned`; wj_str_free releases it). Layout matches wj.h.
Str :: struct {
	ptr:   [^]u8,
	len:   uint,
	owned: bool,
}

// wj_buf: the per-realm scratch buffer. Its layout (data, cap) matches wj.h; `wj_scratch` is the C global.
Buf :: struct {
	data: [^]u8,
	cap:  u32,
}

@(default_calling_convention = "c")
foreign {
	wj_scratch: Buf
}

// A string view of an owned/borrowed Str as an Odin slice (valid until the next conversion or wj_str_free).
str_slice :: #force_inline proc "contextless" (s: Str) -> []u8 {
	return s.ptr != nil ? s.ptr[:s.len] : nil
}

// wj_to_str flags (wj.h) and conversion modes.
STR_NULLABLE   :: i32(1 << 0)
STR_NULL_EMPTY :: i32(1 << 1)
STR_OPTIONAL   :: i32(1 << 2)
STR_USV        :: i32(1 << 3)

ENFORCE_RANGE :: i32(1)
CLAMP         :: i32(2)

// WJ_FETCH_STRING (wj.h is a macro): call `fill(user, scratch.data, scratch.cap)`, growing once if the full length did
// not fit, and return the length (or the negative Error). `fill` runs the browser call with the current scratch buffer;
// `user` carries the call's operands (the macro captured them lexically; Odin passes them explicitly, which keeps this
// re-entrancy-safe, unlike a file-global stash). The bytes land in wj_scratch.data.
Fetch_Fill :: #type proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32
fetch_string :: proc "contextless" (fill: Fetch_Fill, user: rawptr) -> i32 {
	n := fill(user, wj_scratch.data, wj_scratch.cap)
	if n > 0 && u32(n) > wj_scratch.cap {
		if !wj_scratch_grow(u32(n)) { return -13 }   // wr_Error_Quota
		n = fill(user, wj_scratch.data, wj_scratch.cap)
	}
	return n
}

// The bytes currently held in the scratch buffer (length `n`), as a slice (for JS_NewStringLen etc.).
scratch_bytes :: #force_inline proc "contextless" (n: i32) -> []u8 {
	return n > 0 ? wj_scratch.data[:n] : nil
}

// A NUL-terminated copy of `s` on the engine heap (wj.malloc): a cstring for the string-keyed property APIs that take
// one (JS_DefinePropertyValueStr). Free with temp_cstr_free. nil (and a 0-length cstring) on allocation failure.
temp_cstr :: proc "contextless" (s: []u8) -> cstring {
	p := ([^]u8)(wj_malloc(uint(len(s)) + 1))
	if p == nil { return nil }
	if len(s) > 0 { intrinsics_mem_copy(p, raw_data(s), len(s)) }
	p[len(s)] = 0
	return cstring(p)
}
temp_cstr_free :: #force_inline proc "contextless" (s: cstring) { if s != nil { wj_free(rawptr(s)) } }

// A valid non-nil pointer to a zero byte, for the `""` the C passes when a string argument is empty (the browser reads
// no bytes when the length is 0, but a non-nil pointer matches the C exactly and never risks a nil deref at the ABI).
@(private) empty_byte: [1]u8
empty_ptr :: #force_inline proc "contextless" () -> [^]u8 { return &empty_byte[0] }

@(private)
intrinsics_mem_copy :: #force_inline proc "contextless" (dst, src: rawptr, n: int) {
	d := ([^]u8)(dst); s := ([^]u8)(src)
	for i in 0 ..< n { d[i] = s[i] }
}

// ---- wj.h promise kinds (WJ_HOST_*): how a browser promise's value becomes the JS value ----
HOST_UNDEFINED   :: i32(0)
HOST_NUMBER      :: i32(1)
HOST_BOOL        :: i32(2)
HOST_TEXT        :: i32(3)
HOST_ARRAYBUFFER :: i32(4)
HOST_UINT8ARRAY  :: i32(5)

// wj_host_settle: makes the fulfilled value / rejection reason instead of the kind's conversion.
Host_Settle :: #type proc "c" (ctx: ^Context, state: i32, host: u64, value: i64, data: JSValue, reject: ^bool) -> JSValue

// ---- runtime/web.h (real symbols) ----

@(default_calling_convention = "c")
foreign {
	// dictionaries, freeze
	web_freeze     :: proc(ctx: ^Context, v: JSValue) -> bool ---

	// strings
	web_to_usv        :: proc(ctx: ^Context, v: JSValue, out: ^Str) -> bool ---
	web_to_bytestring :: proc(ctx: ^Context, v: JSValue, out: ^Str) -> bool ---
	web_utf8_string   :: proc(ctx: ^Context, p: [^]u8, n: uint, strip_bom: bool) -> JSValue ---
	web_ascii_lower   :: proc(p: [^]u8, n: uint) ---
	web_ascii_ieq     :: proc(a: [^]u8, an: uint, b: cstring) -> bool ---

	// errors as values
	web_error_value   :: proc(ctx: ^Context, code: i32, msg: [^]u8, len: uint) -> JSValue ---
	web_dom_exception :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	web_type_error    :: proc(ctx: ^Context, message: cstring) -> JSValue ---
	web_range_error   :: proc(ctx: ^Context, message: cstring) -> JSValue ---

	// promises as values
	web_promise_new            :: proc(ctx: ^Context, funcs: [^]JSValue) -> JSValue ---
	web_promise_resolved       :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_promise_take           :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_promise_rejected       :: proc(ctx: ^Context, reason: JSValue) -> JSValue ---
	web_promise_reject_pending :: proc(ctx: ^Context) -> JSValue ---
	web_settle                 :: proc(ctx: ^Context, func: JSValue, v: JSValue) ---
	wj_host_promise_text       :: proc(ctx: ^Context, host: u64) -> JSValue ---

	// buffers (buffer.c)
	wj_is_buffer_source     :: proc(v: JSValue) -> bool ---
	wj_is_array_buffer      :: proc(v: JSValue) -> bool ---
	wj_is_array_buffer_view :: proc(v: JSValue) -> bool ---
	wj_to_buffer_source     :: proc(ctx: ^Context, v: JSValue, ptr: ^[^]u8, len: ^uint, flags: i32, what: cstring) -> bool ---
	wj_typed_array_type     :: proc(v: JSValue) -> i32 ---
	wj_arraybuffer_from_host :: proc(ctx: ^Context, buffer: u64) -> JSValue ---
	wj_uint8array_from_host  :: proc(ctx: ^Context, buffer: u64) -> JSValue ---
	wj_host_buffer          :: proc(ctx: ^Context, p: [^]u8, n: uint) -> u64 ---
	wj_arraybuffer_take     :: proc(ctx: ^Context, p: [^]u8, n: uint) -> JSValue ---
	wj_uint8array_take      :: proc(ctx: ^Context, p: [^]u8, n: uint) -> JSValue ---

	// hidden state, events (web_extra_get/set are in wj.odin)
	web_extra     :: proc(ctx: ^Context, obj: JSValue, create: bool) -> JSValue ---
	web_event_host :: proc(ev: JSValue) -> u64 ---
	web_event_new  :: proc(ctx: ^Context, iface: i32, type: cstring, bubbles: bool, cancelable: bool) -> JSValue ---
	web_event_fire :: proc(ctx: ^Context, target: JSValue, ev: JSValue) -> bool ---
	web_fire_simple :: proc(ctx: ^Context, target: JSValue, type: cstring) -> bool ---

	// iterators of pair iterables, sequences, records
	web_iterator_new :: proc(ctx: ^Context, iterable: i32, owner: JSValue, kind: i32, at: Pair_At) -> JSValue ---
	web_for_each     :: proc(ctx: ^Context, owner: JSValue, argc: i32, argv: [^]JSValue, at: Pair_At) -> JSValue ---
	web_is_iterable  :: proc(ctx: ^Context, v: JSValue) -> i32 ---
	web_for_of       :: proc(ctx: ^Context, iterable: JSValue, fn: For_Of_Fn, opaque: rawptr) -> bool ---
	web_for_record   :: proc(ctx: ^Context, obj: JSValue, fn: For_Record_Fn, opaque: rawptr) -> bool ---
	web_then         :: proc(ctx: ^Context, promise: JSValue, on_ok: rawptr, on_err: rawptr, n: i32, data: [^]JSValue) -> JSValue ---
	web_iter_result  :: proc(ctx: ^Context, value: JSValue, done: bool) -> JSValue ---

	web_queue_task   :: proc(ctx: ^Context, fn: Task_Fn, data: JSValue) -> bool ---

	web_pin          :: proc(ctx: ^Context, v: JSValue) -> u32 ---
	web_unpin        :: proc(ctx: ^Context, token: u32) ---
	web_unpin_later  :: proc(ctx: ^Context, token: u32) ---

	web_singleton    :: proc(ctx: ^Context, which: i32, make: proc "c" (ctx: ^Context) -> JSValue) -> JSValue ---

	web_resolve_url  :: proc(ctx: ^Context, s: [^]u8, n: uint, out: ^Str) -> bool ---
	web_status_text  :: proc(status: i32) -> cstring ---
}

// Callback types (match web.h function-pointer typedefs).
Pair_At      :: #type proc "c" (ctx: ^Context, owner: JSValue, index: u32, key: ^JSValue, value: ^JSValue) -> i32
For_Of_Fn    :: #type proc "c" (ctx: ^Context, item: JSValue, opaque: rawptr) -> bool
For_Record_Fn :: #type proc "c" (ctx: ^Context, key: JSValue, value: JSValue, opaque: rawptr) -> bool
Task_Fn      :: #type proc "c" (ctx: ^Context, data: JSValue)

// web.h BufferSource flags, iterator kinds, iterable ids, header guards (enums of web.h).
BS_VIEW_ONLY    :: i32(1 << 0)
BS_ALLOW_SHARED :: i32(1 << 1)

ITER_KEYS    :: i32(0)
ITER_VALUES  :: i32(1)
ITER_ENTRIES :: i32(2)

ITERABLE_HEADERS        :: i32(0)
ITERABLE_URLSEARCHPARAMS :: i32(1)
ITERABLE_FORMDATA       :: i32(2)

// web.h singleton ids.
SINGLE_LOCATION       :: i32(0)
SINGLE_HISTORY        :: i32(1)
SINGLE_NAVIGATOR      :: i32(2)
SINGLE_LOCAL_STORAGE  :: i32(3)
SINGLE_SESSION_STORAGE :: i32(4)
SINGLE_PERFORMANCE    :: i32(5)
SINGLE_CRYPTO         :: i32(6)
SINGLE_SUBTLE         :: i32(7)
SINGLE_SCREEN         :: i32(8)
SINGLE_CREDENTIALS    :: i32(9)
SINGLE_CLIPBOARD      :: i32(10)
SINGLE_VISUAL_VIEWPORT :: i32(11)
SINGLE_PERMISSIONS    :: i32(12)
SINGLE_FONTS          :: i32(13)
SINGLE_CACHES         :: i32(14)
SINGLE_SERVICE_WORKER :: i32(15)
SINGLE_STORAGE        :: i32(16)
SINGLE_TIMELINE       :: i32(17)

// ---- Blob / File / FormData / Headers / streams / abort / entries (web.h real symbols G2 domains call) ----

@(default_calling_convention = "c")
foreign {
	web_blob_bytes   :: proc(v: JSValue, ptr: ^[^]u8, len: ^uint) -> bool ---
	web_blob_type    :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_blob_new     :: proc(ctx: ^Context, p: [^]u8, n: uint, type: cstring, type_len: uint) -> JSValue ---
	web_file_new     :: proc(ctx: ^Context, p: [^]u8, n: uint, type: cstring, type_len: uint, name: cstring, name_len: uint, last_modified: f64) -> JSValue ---
	web_file_from_host :: proc(ctx: ^Context, local_file: u64) -> JSValue ---
	web_entry_wrap   :: proc(ctx: ^Context, entry: u64) -> JSValue ---
	web_file_host    :: proc(v: JSValue) -> u64 ---
	web_file_meta    :: proc(ctx: ^Context, v: JSValue, name: ^Str, type: ^Str, last_modified: ^f64) -> bool ---
	web_blob_url_lookup :: proc(ctx: ^Context, url: [^]u8, n: uint) -> JSValue ---

	web_formdata_is     :: proc(v: JSValue) -> bool ---
	web_formdata_handle :: proc(v: JSValue) -> u64 ---
	web_formdata_new    :: proc(ctx: ^Context) -> JSValue ---
	web_formdata_append :: proc(ctx: ^Context, fd: JSValue, name: JSValue, value: JSValue, filename: JSValue) -> bool ---
	web_formdata_parse  :: proc(ctx: ^Context, p: [^]u8, n: uint, content_type: cstring, ct_len: uint) -> JSValue ---

	web_headers_new             :: proc(ctx: ^Context, guard: i32) -> JSValue ---
	web_headers_fill_lines      :: proc(ctx: ^Context, headers: JSValue, text: cstring, n: uint) ---
	web_headers_get             :: proc(headers: JSValue, name: cstring, len: ^uint) -> [^]u8 ---
	web_headers_has             :: proc(headers: JSValue, name: cstring) -> bool ---
	web_headers_append_raw      :: proc(headers: JSValue, name: cstring, nlen: uint, value: cstring, vlen: uint) -> bool ---
	web_headers_append_checked  :: proc(ctx: ^Context, headers: JSValue, name: cstring, nlen: uint, value: cstring, vlen: uint) -> bool ---
	web_headers_sorted          :: proc(ctx: ^Context, headers: JSValue) -> JSValue ---
	web_forbidden_request_header :: proc(name: cstring, n: uint, value: cstring, vn: uint) -> bool ---

	web_stream_is        :: proc(v: JSValue) -> bool ---
	web_stream_locked    :: proc(v: JSValue) -> bool ---
	web_stream_disturbed :: proc(v: JSValue) -> bool ---
	web_stream_from_host :: proc(ctx: ^Context, host_stream: u64, signal: JSValue, keep: JSValue) -> JSValue ---
	web_stream_from_bytes :: proc(ctx: ^Context, p: [^]u8, n: uint) -> JSValue ---
	web_stream_of        :: proc(ctx: ^Context, chunk: JSValue) -> JSValue ---
	web_stream_pending   :: proc(ctx: ^Context) -> JSValue ---
	web_stream_push      :: proc(ctx: ^Context, stream: JSValue, chunk: JSValue) ---
	web_stream_end       :: proc(ctx: ^Context, stream: JSValue) ---
	web_stream_fail      :: proc(ctx: ^Context, stream: JSValue, e: JSValue) ---
	web_stream_read_all  :: proc(ctx: ^Context, stream: JSValue) -> JSValue ---
	web_stream_tee       :: proc(ctx: ^Context, stream: JSValue, clone_second: bool) -> JSValue ---
	web_stream_cancel    :: proc(ctx: ^Context, stream: JSValue, reason: JSValue) -> JSValue ---
	web_stream_state     :: proc(ctx: ^Context, v: JSValue, error: ^JSValue) -> i32 ---
	web_writable_state   :: proc(ctx: ^Context, v: JSValue, error: ^JSValue) -> i32 ---

	web_signal_handle    :: proc(v: JSValue) -> u64 ---
	web_signal_reason    :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_signal_aborted   :: proc(v: JSValue) -> bool ---
	web_signal_wrap_as   :: proc(ctx: ^Context, h: u64, iface: i32) -> JSValue ---
	web_controller_construct :: proc(ctx: ^Context, new_target: JSValue, controller_iface: i32, signal_iface: i32) -> JSValue ---
	web_signal_any       :: proc(ctx: ^Context, iterable: JSValue, result_iface: i32, who: cstring) -> JSValue ---

	web_extract_body     :: proc(ctx: ^Context, v: JSValue, out: ^Extracted, what: cstring) -> bool ---
	web_extracted_free   :: proc(ctx: ^Context, e: ^Extracted) ---
}

// web_extracted (web.h): the bytes, Content-Type and a kept ReadableStream of "extract a body".
Extracted :: struct {
	data:   [^]u8,
	len:    uint,
	type:   cstring,
	stream: JSValue,
}

// ---- the C field accessors of wj_g2_shim.c (wj_obj.handle/impl, wj_the_realm.protos[iface]) ----

@(default_calling_convention = "c")
foreign {
	wj_g2_obj_handle :: proc(v: JSValue) -> u64 ---
	wj_g2_obj_impl   :: proc(v: JSValue) -> rawptr ---
	wj_g2_handle     :: proc(obj: rawptr) -> u64 ---
	wj_g2_impl       :: proc(obj: rawptr) -> rawptr ---
	wj_g2_proto      :: proc(iface: i32) -> JSValue ---
}

// The browser handle behind a platform object `v` (0 when none). Same as reading wj_obj_of(v)->handle.
obj_handle :: #force_inline proc "contextless" (v: JSValue) -> u64 { return wj_g2_obj_handle(v) }
obj_impl   :: #force_inline proc "contextless" (v: JSValue) -> rawptr { return wj_g2_obj_impl(v) }
// The handle / impl off a wj_obj* (what wj_this / wj_unwrap return).
handle_of  :: #force_inline proc "contextless" (obj: rawptr) -> u64 { return wj_g2_handle(obj) }
impl_of    :: #force_inline proc "contextless" (obj: rawptr) -> rawptr { return wj_g2_impl(obj) }
proto_of   :: #force_inline proc "contextless" (iface: i32) -> JSValue { return wj_g2_proto(iface) }

// web_this_impl is declared in wj.odin; this_impl mirrors the C name used across runtime/web.
this_impl  :: #force_inline proc "contextless" (ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr {
	return web_this_impl(ctx, this_val, iface)
}
