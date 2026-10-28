// package wj, G1 additions: the engine/runtime surface the DOM, events, shadow DOM, custom elements and frames glue
// (native/js/odin/*.odin ported from native/js/runtime/dom_*.c, events.c, handlers.c, shadow.c, custom_elements.c,
// frames.c, intersection.c, web_resize.c) builds on, beyond the minimal set of wj.odin. It mirrors, for the Odin side:
//
//   * the QuickJS-ng functions these domains call that wj.odin did not yet declare (real symbols, foreign blocks);
//   * the inline value helpers they use (JS_NewObject-style constructors, JS_VALUE_GET_PTR, the JS_UNINITIALIZED
//     sentinel), reimplemented from quickjs.h as in wj.odin;
//   * the engine/runtime helper functions (wj_*, web_*) with real symbols;
//   * the host imports (wr_*) these domains reach, resolved by wasm-ld to the module's imports;
//   * the shared C structs a ported domain reads or writes through a pointer (wj_obj, wj_interface, wj_listener,
//     wj_realm, dom_impl, wr_TouchPoint, wr_DomRect). Their layout matches the C exactly (same field order and types,
//     same wasm32 C ABI), so a pointer the engine hands over is read and written in place with no copy or marshalling.
//
// This file is G1-owned (BRIEF: never edit wj.odin; add what G1 needs here). Names and signatures match the C.
package wj

// ---- more NAN-boxed sentinels / tags the glue uses ----

// JS_TAG_UNINITIALIZED (quickjs.h) == -10: the "no value yet" marker frames.c and the exotic objects use as "not found".
// The sentinel is JS_MKVAL(-10, 0): the tag (-10, as u32 = 0xFFFFFFF6) in the high word, 0 in the low word.
Uninitialized_Tag :: i32(-10)
UNINITIALIZED :: JSValue(u64(0xFFFF_FFF6) << 32)

is_uninitialized :: #force_inline proc "contextless" (v: JSValue) -> bool { return tag_of(v) == Uninitialized_Tag }

// the pointer a reference-counted JSValue holds (quickjs.h JS_VALUE_GET_PTR): the low 48 bits on NAN boxing. Used for
// object identity (same wrapper, same listener callback) where the C compares JS_VALUE_GET_PTR(a) == JS_VALUE_GET_PTR(b).
value_get_ptr :: #force_inline proc "contextless" (v: JSValue) -> rawptr {
	return rawptr(uintptr(v & 0x0000_FFFF_FFFF_FFFF))
}
// JS_VALUE_GET_INT: the int payload (low 32 bits) of an int-tagged value.
value_get_int :: #force_inline proc "contextless" (v: JSValue) -> i32 { return i32(u32(v)) }

same_ptr :: #force_inline proc "contextless" (a, b: JSValue) -> bool { return value_get_ptr(a) == value_get_ptr(b) }

// ---- more inline value constructors / predicates ----

new_uint32 :: #force_inline proc "contextless" (ctx: ^Context, v: u32) -> JSValue {
	// QuickJS JS_NewUint32: fits in an int when < 2^31, else a float.
	return v <= u32(max(i32)) ? new_int32(i32(v)) : JS_NewNumber(ctx, f64(v))
}

// ---- opaque QuickJS types used only behind a pointer or as a value ----

Atom :: distinct u32   // JSAtom
Runtime_Ptr :: ^Runtime

// ---- engine functions (real symbols), the DOM/events/etc. domains use ----

@(default_calling_convention = "c")
foreign {
	// values (real JS_EXTERN symbols; the static-inline wrappers are reimplemented below)
	JS_NewStringLen   :: proc(ctx: ^Context, s: [^]u8, len: uint) -> JSValue ---
	JS_ToString       :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	JS_ToBool         :: proc(ctx: ^Context, v: JSValue) -> i32 ---   // -1 on exception
	JS_ToInt64        :: proc(ctx: ^Context, pres: ^i64, v: JSValue) -> i32 ---
	JS_ToCStringLen2  :: proc(ctx: ^Context, plen: ^uint, v: JSValue, cesu8: bool) -> cstring ---
	JS_FreeCString    :: proc(ctx: ^Context, p: cstring) ---
	JS_FreeValueRT    :: proc(rt: ^Runtime, v: JSValue) ---

	// objects / arrays / properties
	JS_NewObject            :: proc(ctx: ^Context) -> JSValue ---
	JS_NewObjectProto       :: proc(ctx: ^Context, proto: JSValue) -> JSValue ---
	JS_NewObjectClass       :: proc(ctx: ^Context, class_id: u32) -> JSValue ---
	JS_NewArray             :: proc(ctx: ^Context) -> JSValue ---
	JS_IsArray              :: proc(v: JSValue) -> bool ---
	JS_GetProperty          :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom) -> JSValue ---
	JS_GetPropertyUint32    :: proc(ctx: ^Context, this_obj: JSValue, idx: u32) -> JSValue ---
	JS_GetPropertyInt64     :: proc(ctx: ^Context, this_obj: JSValue, idx: i64) -> JSValue ---
	JS_SetPropertyStr       :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue) -> i32 ---
	JS_SetPropertyUint32    :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue) -> i32 ---
	JS_SetPropertyInt64     :: proc(ctx: ^Context, this_obj: JSValue, idx: i64, val: JSValue) -> i32 ---
	JS_DefinePropertyValueStr :: proc(ctx: ^Context, this_obj: JSValue, prop: cstring, val: JSValue, flags: i32) -> i32 ---
	JS_DefinePropertyValueUint32 :: proc(ctx: ^Context, this_obj: JSValue, idx: u32, val: JSValue, flags: i32) -> i32 ---
	JS_HasProperty          :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom) -> i32 ---
	JS_GetLength            :: proc(ctx: ^Context, obj: JSValue, pres: ^i64) -> i32 ---
	JS_IsStrictEqual        :: proc(ctx: ^Context, a: JSValue, b: JSValue) -> bool ---
	JS_IsConstructor        :: proc(ctx: ^Context, v: JSValue) -> bool ---

	// calls
	JS_Call            :: proc(ctx: ^Context, func_obj: JSValue, this_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_CallConstructor :: proc(ctx: ^Context, func_obj: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---

	// errors
	JS_Throw             :: proc(ctx: ^Context, exc: JSValue) -> JSValue ---
	JS_GetException      :: proc(ctx: ^Context) -> JSValue ---
	JS_HasException      :: proc(ctx: ^Context) -> bool ---
	JS_ThrowRangeError   :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---

	// atoms
	JS_NewAtom        :: proc(ctx: ^Context, s: cstring) -> Atom ---
	JS_NewAtomLen     :: proc(ctx: ^Context, s: [^]u8, len: uint) -> Atom ---
	JS_FreeAtom       :: proc(ctx: ^Context, a: Atom) ---
	JS_ValueToAtom    :: proc(ctx: ^Context, v: JSValue) -> Atom ---
	JS_AtomToValue    :: proc(ctx: ^Context, a: Atom) -> JSValue ---

	// malloc on the engine's heap (js_malloc / js_free of quickjs.h)
	js_malloc         :: proc(ctx: ^Context, n: uint) -> rawptr ---
	js_free           :: proc(ctx: ^Context, p: rawptr) ---

	// GC threshold (custom elements pauses the collector while it wraps a batch of removed nodes)
	JS_GetGCThreshold :: proc(rt: ^Runtime) -> uint ---
	JS_SetGCThreshold :: proc(rt: ^Runtime, gc_threshold: uint) ---
}

// the static-inline value wrappers of quickjs.h, reimplemented (no symbol; NAN-box bit ops / thin forwarders).
JS_NewBool :: #force_inline proc "contextless" (ctx: ^Context, b: bool) -> JSValue { return new_bool(b) }
JS_NewInt64 :: #force_inline proc "contextless" (ctx: ^Context, v: i64) -> JSValue {
	// quickjs JS_NewInt64: an int32 when it fits, else a float64 (via the engine's JS_NewNumber).
	i := i32(v)
	return i64(i) == v ? new_int32(i) : JS_NewNumber(ctx, f64(v))
}
JS_NewString :: #force_inline proc "contextless" (ctx: ^Context, s: cstring) -> JSValue {
	return JS_NewStringLen(ctx, ([^]u8)(rawptr(s)), uint(len(s)))
}
JS_ToCStringLen :: #force_inline proc "contextless" (ctx: ^Context, plen: ^uint, v: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, plen, v, false)
}
JS_ToCString :: #force_inline proc "contextless" (ctx: ^Context, v: JSValue) -> cstring {
	return JS_ToCStringLen2(ctx, nil, v, false)
}

// JSCFunctionData (quickjs.h): a native function carrying bound data (func_data[0..n)).
Native_Data :: #type proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32, func_data: [^]JSValue) -> JSValue

@(default_calling_convention = "c")
foreign {
	JS_NewCFunctionData   :: proc(ctx: ^Context, fn: Native_Data, length: i32, magic: i32, data_len: i32, data: [^]JSValue) -> JSValue ---
	JS_NewCFunctionData2  :: proc(ctx: ^Context, fn: Native_Data, name: cstring, length: i32, magic: i32, data_len: i32, data: [^]JSValue) -> JSValue ---
	JS_DefinePropertyGetSet :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, getter: JSValue, setter: JSValue, flags: i32) -> i32 ---
}

// JS property flags (quickjs.h JS_PROP_*), the ones the glue uses.
PROP_CONFIGURABLE :: 1 << 0
PROP_WRITABLE     :: 1 << 1
PROP_ENUMERABLE   :: 1 << 2
PROP_C_W_E        :: PROP_CONFIGURABLE | PROP_WRITABLE | PROP_ENUMERABLE

// Element i of an array/holder (JS_DefinePropertyValueUint32 with C_W_E): a data property, never [[Set]]. -1 throws.
array_set :: #force_inline proc "contextless" (ctx: ^Context, arr: JSValue, i: u32, v: JSValue) -> i32 {
	return JS_DefinePropertyValueUint32(ctx, arr, i, v, PROP_C_W_E)
}

// ---- engine/runtime helper functions (wj_*, native/js/engine and runtime) ----

@(default_calling_convention = "c")
foreign {
	// platform-object access
	wj_unwrap          :: proc(v: JSValue, iface: i32) -> ^Obj ---
	wj_this            :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> ^Obj ---
	wj_wrap_node       :: proc(ctx: ^Context, node: u64) -> JSValue ---
	wj_wrap_host       :: proc(ctx: ^Context, handle: u64, iface: i32) -> JSValue ---
	wj_cached          :: proc(ctx: ^Context, handle: u64) -> JSValue ---
	wj_new_object_for  :: proc(ctx: ^Context, iface: i32, new_target: JSValue, impl: rawptr, impl_free: proc "c" (p: rawptr)) -> JSValue ---
	wj_wrap_owned      :: proc(ctx: ^Context, handle: u64, iface: i32, new_target: JSValue) -> JSValue ---
	wj_mark            :: proc(rt: rawptr, v: JSValue, mark_func: rawptr) ---

	// errors / status
	wj_throw_type      :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_range     :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_dom       :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	wj_throw_status    :: proc(ctx: ^Context, status: i32, what: cstring) -> JSValue ---
	wj_throw_arity     :: proc(ctx: ^Context, what: cstring, required: i32, given: i32) -> JSValue ---
	wj_report_pending  :: proc(ctx: ^Context) ---
	wj_report_exception :: proc(ctx: ^Context, exc: JSValue) ---

	// Web IDL conversions
	wj_to_int32  :: proc(ctx: ^Context, v: JSValue, out: ^i32, bits: i32, mode: i32) -> bool ---
	wj_to_uint32 :: proc(ctx: ^Context, v: JSValue, out: ^u32, bits: i32, mode: i32) -> bool ---
	wj_to_double :: proc(ctx: ^Context, v: JSValue, out: ^f64, restricted: bool) -> bool ---
	wj_to_str    :: proc(ctx: ^Context, v: JSValue, out: ^Str, flags: i32, def: cstring) -> bool ---
	wj_str_free  :: proc(ctx: ^Context, s: ^Str) ---
	wj_to_handle :: proc(ctx: ^Context, v: JSValue, iface: i32, nullable: bool, out: ^u64, message: cstring) -> bool ---

	// scratch buffer growth (the WJ_FETCH_STRING retry; wj_scratch itself is the global below)
	wj_scratch_grow :: proc(need: u32) -> bool ---

	// stack budget (the exported callbacks call wj_stack_enter)
	wj_stack_enter  :: proc(ctx: ^Context) ---

	// event machinery (native/js/runtime/events.c; still C until events.odin is ported, then an Odin export of the
	// same name). A hand-written Event subclass constructor calls this to build the Event and read EventInit.
	wj_event_construct :: proc(ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue, iface: i32, name: cstring) -> JSValue ---
}

// ---- runtime/web.h helpers (real symbols) ----

@(default_calling_convention = "c")
foreign {
	web_pin          :: proc(ctx: ^Context, v: JSValue) -> u32 ---
	web_unpin        :: proc(ctx: ^Context, token: u32) ---
	web_freeze       :: proc(ctx: ^Context, v: JSValue) -> bool ---
	web_strndup      :: proc(p: cstring, n: uint) -> cstring ---
	web_ascii_ieq    :: proc(a: cstring, an: uint, b: cstring) -> bool ---
	web_for_of       :: proc(ctx: ^Context, iterable: JSValue, fn: proc "c" (ctx: ^Context, item: JSValue, opaque: rawptr) -> bool, opaque: rawptr) -> bool ---
	web_is_iterable  :: proc(ctx: ^Context, v: JSValue) -> i32 ---
	web_event_host   :: proc(ev: JSValue) -> u64 ---
	web_event_new    :: proc(ctx: ^Context, iface: i32, type: cstring, bubbles: bool, cancelable: bool) -> JSValue ---
	web_event_fire   :: proc(ctx: ^Context, target: JSValue, ev: JSValue) -> bool ---
	web_type_error   :: proc(ctx: ^Context, message: cstring) -> JSValue ---
	web_dom_exception :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	web_promise_new      :: proc(ctx: ^Context, funcs: ^[2]JSValue) -> JSValue ---
	web_promise_resolved :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_promise_rejected :: proc(ctx: ^Context, reason: JSValue) -> JSValue ---
	web_promise_reject_pending :: proc(ctx: ^Context) -> JSValue ---
}

// ---- shared C structs (layout matches the C exactly: same wasm32 ABI) ----

// A UTF-8 view of a converted string (wj.h wj_str).
Str :: struct {
	ptr:   cstring,
	len:   uint,
	owned: bool,
}

// wj.h wj_listener: an event listener or handler on a platform object. Only events.c/handlers.c touch its fields; other
// files only pass it by pointer.
Listener :: struct {
	next:     ^Listener,
	callback: JSValue,
	type:     JSValue,
	host_id:  i32,
	slot:     u32,
	capture:  u8,
	once:     u8,
	passive:  u8,
	handler:  u8,
	owner:    ^Obj,
}

// wj.h wj_obj: the platform object behind a JS wrapper (its interface, the browser's handle, the JS values it keeps).
Obj :: struct {
	handle:     u64,
	iface:      u16,
	kind:       u8,
	flags:      u8,
	group_slot: u32,
	group:      rawptr,     // wj_group *, opaque to the glue
	group_val:  JSValue,
	listeners:  ^Listener,
	impl:       rawptr,
	impl_free:  proc "c" (impl: rawptr),
	impl_mark:  proc "c" (rt: rawptr, impl: rawptr, mark_func: rawptr),
	self:       JSValue,
	same:       [^]JSValue,
	n_same:     u16,
}

// wj_obj.kind values (wj.h).
KIND_NONE   :: 0
KIND_NODE   :: 1
KIND_HOST   :: 2
KIND_GLOBAL :: 3

// wj.h wj_interface (only the fields the glue reads: parent/subtree_end for range checks). The tail function pointers
// are left out safely only if nothing reads them; the glue reads .subtree_end and .name, so the full head is mirrored
// up to subtree_end. To stay ABI-correct for `wj_interfaces[i]`, the whole struct is mirrored.
Interface :: struct {
	name:        cstring,
	parent:      i16,
	exposed:     u16,
	flags:       u16,
	class_kind:  u8,
	ctor_length: u16,
	ctor:        rawptr,
	members:     rawptr,
	n_members:   u16,
	subtree_end: u16,
	index_get:   rawptr,
	length_get:  rawptr,
	named_get:   rawptr,
	named_set:   rawptr,
	named_delete: rawptr,
	named_keys:  rawptr,
	legacy_alias: cstring,
	factory_name: cstring,
	factory:     rawptr,
	factory_length: u16,
}

// wj.h wj_realm.
Realm :: struct {
	ctx:            ^Context,
	kind:           i32,
	scope:          i32,
	global_obj:     Obj,
	global:         JSValue,
	protos:         [^]JSValue,
	ctors:          [^]JSValue,
	started:        bool,
	in_gc_prologue: bool,
}

// dom_internal.h dom_impl: an engine object's DOM data (lists, token lists, styles, rects, value holders).
Dom_Impl :: struct {
	kind:     i32,
	owner:    JSValue,
	node:     u64,
	coll:     u64,
	nodes:    [^]u64,
	n:        u32,
	name:     [^]u8,
	name_len: uint,
	extra:    JSValue,
	rect:     [4]f64,
	values:   [^]JSValue,
	n_values: u32,
}

// dom_internal.h DOM_* kinds.
DOM_LIST_LIVE     :: 1
DOM_LIST_STATIC   :: 2
DOM_TOKENS        :: 3
DOM_DATASET       :: 4
DOM_ATTRS         :: 5
DOM_ATTR          :: 6
DOM_STYLE_INLINE  :: 7
DOM_STYLE_COMPUTED :: 8
DOM_RECT          :: 9
DOM_VALUES        :: 10

// wj.h wj_str flags.
STR_NULLABLE   :: 1 << 0
STR_NULL_EMPTY :: 1 << 1
STR_OPTIONAL   :: 1 << 2
STR_USV        :: 1 << 3

// wr_TouchPoint (gen/wren_api.h): a touch point in a TouchEvent. identifier is i32 then a u64 (8-byte aligned, so a
// 4-byte hole after identifier); Odin's default struct layout on wasm32 reproduces the C padding.
Wr_TouchPoint :: struct {
	identifier:     i32,
	target:         u64,
	client_x:       f64,
	client_y:       f64,
	screen_x:       f64,
	screen_y:       f64,
	page_x:         f64,
	page_y:         f64,
	radius_x:       f64,
	radius_y:       f64,
	rotation_angle: f64,
	force:          f64,
}

// wr_DomRect (gen/wren_api.h).
Wr_DomRect :: struct {
	x:      f64,
	y:      f64,
	width:  f64,
	height: f64,
}

// ---- the C globals the glue reads (real symbols) ----

@(default_calling_convention = "c")
foreign {
	wj_the_realm:    Realm        // the one realm
	wj_scratch:      Scratch      // the shared string scratch buffer
	wj_interfaces:   [^]Interface // the generated interface table
	wj_interface_count: i32       // its length
	wj_class_plain:  u32          // JSClassID of the plain platform class (for wj_obj_of)
	wj_class_indexed: u32
	wj_class_named:  u32
	wj_dispatch_trusted: bool
}

// wj.h wj_buf (wj_scratch's type): a growable byte buffer the browser fills string results into.
Scratch :: struct {
	data: [^]u8,
	cap:  u32,
}

// ---- C library memory (wasi-libc, in the module): the glue uses the engine's malloc/free via wj_malloc/wj_free
// (wj.odin) for engine-owned data; the per-object impls of the DOM glue were malloc'ed with the C library's own
// malloc/calloc/realloc/free in the original C, so the Odin port keeps using those exact symbols to free them the same
// way. memcpy/memcmp are the ones wasi-libc / the Odin runtime provide.

@(default_calling_convention = "c")
foreign {
	calloc  :: proc(n: uint, size: uint) -> rawptr ---
	realloc :: proc(p: rawptr, size: uint) -> rawptr ---
	memcmp  :: proc(a: rawptr, b: rawptr, n: uint) -> i32 ---
	memcpy  :: proc(dst: rawptr, src: rawptr, n: uint) -> rawptr ---
}
// malloc / free are already exposed as wj.malloc / wj.free? No: those are the engine heap (wj_malloc). The DOM glue's
// per-object impls used the C library malloc/free; keep them distinct.
@(default_calling_convention = "c")
foreign {
	@(link_name = "malloc") libc_malloc :: proc(n: uint) -> rawptr ---
	@(link_name = "free")   libc_free   :: proc(p: rawptr) ---
}

// JS_GetClassID / JS_GetOpaque (quickjs.h): used to reimplement wj_obj_of in Odin (qjs_internal.h's is static inline).
@(default_calling_convention = "c")
foreign {
	JS_GetClassID :: proc(v: JSValue) -> u32 ---
	JS_GetOpaque  :: proc(v: JSValue, class_id: u32) -> rawptr ---
	JS_SetOpaque  :: proc(v: JSValue, p: rawptr) -> i32 ---
}

// wj_obj_of (qjs_internal.h, static inline): the wj_obj of any platform object (any platform class), or nil.
obj_of :: proc "contextless" (v: JSValue) -> ^Obj {
	if !is_object(v) { return nil }
	id := JS_GetClassID(v)
	if id != wj_class_plain && id != wj_class_indexed && id != wj_class_named { return nil }
	return (^Obj)(JS_GetOpaque(v, id))
}

// ---- dom_internal.h helpers (real symbols in dom_core.c / dom_layout.c; declared here for the ported domains) ----

@(default_calling_convention = "c")
foreign {
	dom_new       :: proc(ctx: ^Context, iface: i32, kind: i32, owner: JSValue, node: u64, out: ^^Dom_Impl) -> JSValue ---
	dom_impl_of   :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> ^Dom_Impl ---
	dom_strndup   :: proc(s: [^]u8, n: uint) -> [^]u8 ---
	dom_node_arg  :: proc(ctx: ^Context, v: JSValue, out: ^u64, nullable: bool, what: cstring) -> bool ---
	dom_dict_get  :: proc(ctx: ^Context, dict: JSValue, name: cstring) -> JSValue ---
	dom_live_list :: proc(ctx: ^Context, owner: JSValue, root: u64, kind: i32, arg: [^]u8, arg_len: uint, iface: i32) -> JSValue ---
}
// dom_rect_new / dom_rect_list: defined by the ported dom_layout.odin as @(export) procs in package odin_glue, so the
// ported domains call the package-local ones (not via wj). While dom_layout stays C they are C symbols the C linker
// resolves among themselves; the Odin callers that need them live in odin_glue and declare the foreign fallback there.

// read a little-endian u64 / u32 from a byte buffer (dom_internal.h dom_read_u64 / dom_read_u32, static inline).
read_u64 :: proc "contextless" (p: [^]u8) -> u64 {
	v: u64
	for k in 0..<8 { v |= u64(p[k]) << uint(8 * k) }
	return v
}
read_u32 :: proc "contextless" (p: [^]u8) -> u32 {
	return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24
}

// WJ_FETCH_STRING (wj.h macro): call `fill(scratch.data, scratch.cap)` growing the scratch until the result fits.
// `fill` returns a full byte length or a negative Error. Returns the length or the negative Error.
fetch_string :: proc "contextless" (fill: proc "contextless" () -> i32) -> i32 {
	n := fill()
	if n > 0 && u32(n) > wj_scratch.cap {
		if !wj_scratch_grow(u32(n)) { return -13 }
		n = fill()
	}
	return n
}

@(private) _empty_byte: [1]u8   // a valid pointer to zero bytes (for empty (ptr,len) arguments)

// Pass a string literal to a wr_* import as (ptr, len): the bytes of the literal as [^]u8. The literal is static
// read-only data; the host reads it without keeping it.
raw_bytes :: #force_inline proc "contextless" (s: string) -> [^]u8 { return len(s) > 0 ? raw_data(s) : &_empty_byte[0] }
// A cstring's bytes as [^]u8 (for wr_* (ptr,len) arguments taking a converted wj_str). nil-safe: a nil cstring maps to
// a valid empty pointer, matching the C `s.ptr ? s.ptr : ""` idiom callers apply before calling.
cstr_bytes :: #force_inline proc "contextless" (s: cstring) -> [^]u8 { return s != nil ? ([^]u8)(rawptr(s)) : &_empty_byte[0] }
// A byte buffer the engine filled (wj_scratch.data) as a cstring for helpers taking `const char *` (NUL-terminated by
// those helpers' contract, or used with an explicit length elsewhere).
cstr :: #force_inline proc "contextless" (p: [^]u8) -> cstring { return cstring(rawptr(p)) }

// Compare a cstring (NUL-terminated) against an Odin string literal, byte for byte.
str_eq :: proc "contextless" (a: cstring, b: string) -> bool {
	pa := ([^]u8)(rawptr(a))
	if pa == nil { return false }
	for i in 0..<len(b) {
		if pa[i] != b[i] || pa[i] == 0 { return false }
	}
	return pa[len(b)] == 0
}

// web_set_impl (web.h, static inline): set the impl, its free and mark on a platform object.
set_impl :: proc "contextless" (obj: JSValue, impl: rawptr, impl_free: proc "c" (p: rawptr), impl_mark: proc "c" (rt: rawptr, p: rawptr, mark: rawptr)) {
	o := obj_of(obj)
	if o == nil { return }
	o.impl = impl
	o.impl_free = impl_free
	o.impl_mark = impl_mark
}
