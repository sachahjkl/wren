// host.odin: the wj.h / web.h functions a ported domain calls (platform objects, wrappers, the realm's singletons,
// dictionaries, iterators, host promises, events, queued tasks), the engine's malloc, the interface table, and the
// tiny C field accessors of wj_shim.c (fields of global C structs have no symbol, so one-line accessors expose them).
// One declaration per symbol.
package wj

// ---- the engine's malloc and the interface table (wj.h real symbols) ----

@(default_calling_convention = "c")
foreign {
	// index of an interface by name in the generated table, -1 when unknown (avoids hardcoding WJ_IFACE_* numbers)
	wj_interface_find :: proc(name: cstring) -> i32 ---
	// a new platform object of `iface` with engine-owned data (impl, freed by impl_free); EXCEPTION on failure
	wj_new_object :: proc(ctx: ^Context, iface: i32, impl: rawptr, impl_free: proc "c" (p: rawptr)) -> JSValue ---
	// the realm's shared scratch allocator (the engine's malloc)
	wj_malloc :: proc(n: uint) -> rawptr ---
	wj_free   :: proc(p: rawptr) ---
}

// Resolve an interface index by name (cached by the caller if hot). Returns -1 when unknown.
iface :: #force_inline proc "contextless" (name: cstring) -> i32 { return wj_interface_find(name) }

malloc :: #force_inline proc "contextless" (n: uint) -> rawptr { return wj_malloc(n) }
free   :: #force_inline proc "contextless" (p: rawptr) { wj_free(p) }

// ---- platform objects, wrappers, conversions to a handle (wj.h real symbols) ----

@(default_calling_convention = "c")
foreign {
	// the impl of `this` when it is a platform object of `iface` made by the engine (nil + TypeError otherwise)
	web_this_impl :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr ---

	wj_this         :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr --- // ^wj_obj or nil (+ TypeError)
	// ^Wj_Obj or nil (no throw). Returned as ^Wj_Obj so a caller can read `.handle` directly (qjs_convert); it also
	// decays to rawptr where the caller wants the impl (impl_of).
	wj_unwrap       :: proc(v: JSValue, iface: i32) -> ^Wj_Obj ---
	wj_obj_impl     :: proc(o: rawptr) -> rawptr ---                                     // impl of a wj_obj* (wj_shim.c)
	wj_wrap_node    :: proc(ctx: ^Context, node: u64) -> JSValue ---
	wj_wrap_host    :: proc(ctx: ^Context, handle: u64, iface: i32) -> JSValue ---
	wj_cached       :: proc(ctx: ^Context, handle: u64) -> JSValue ---
	wj_wrap_owned   :: proc(ctx: ^Context, handle: u64, iface: i32, new_target: JSValue) -> JSValue ---
	wj_new_object_for :: proc(ctx: ^Context, iface: i32, new_target: JSValue, impl: rawptr, impl_free: proc "c" (p: rawptr)) -> JSValue ---

	// wj_to_handle (the browser object behind a platform object) is NOT declared here: it is implemented by the Odin
	// glue (qjs_convert.odin); a ported domain (package odin_glue) calls it unqualified. See docs/js/odin-glue.md.

	// misc engine entry points the glue reaches
	wj_report_exception :: proc(ctx: ^Context, exc: JSValue) ---
	wj_report_pending   :: proc(ctx: ^Context) ---   // report the pending exception as uncaught (qjs_internal.h)
	wj_stack_enter      :: proc(ctx: ^Context) ---
	wj_mark             :: proc(rt: rawptr, v: JSValue, mark_func: rawptr) ---
}

// A view of the leading field of C's `wj_obj` (wj.h): only `handle` is mirrored (the first field, offset 0), and only
// ever read through a pointer wj_this/wj_unwrap returned. The full struct is larger; prefer web_this_impl for `impl`.
Wj_Obj :: struct {
	handle: u64,
}

// ---- the realm's singletons, dictionaries, events, iterators, promises, tasks (web.h real symbols) ----

Singleton_Make :: #type proc "c" (ctx: ^Context) -> JSValue
Impl_Free      :: #type proc "c" (p: rawptr)
Impl_Mark      :: #type proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr)
Task_Fn        :: #type proc "c" (ctx: ^Context, data: JSValue)

// Callback types (match web.h function-pointer typedefs).
Pair_At       :: #type proc "c" (ctx: ^Context, owner: JSValue, index: u32, key: ^JSValue, value: ^JSValue) -> i32
For_Of_Fn     :: #type proc "c" (ctx: ^Context, item: JSValue, opaque: rawptr) -> bool
For_Record_Fn :: #type proc "c" (ctx: ^Context, key: JSValue, value: JSValue, opaque: rawptr) -> bool

@(default_calling_convention = "c")
foreign {
	// dictionaries, freeze, hidden state
	web_freeze    :: proc(ctx: ^Context, v: JSValue) -> bool ---
	web_dict_check :: proc(ctx: ^Context, dict: JSValue, what: cstring) -> bool ---
	web_dict_get  :: proc(ctx: ^Context, dict: JSValue, name: cstring, out: ^JSValue) -> bool ---
	web_extra     :: proc(ctx: ^Context, obj: JSValue, create: bool) -> JSValue ---
	web_extra_get :: proc(ctx: ^Context, obj: JSValue, name: cstring) -> JSValue ---
	web_extra_set :: proc(ctx: ^Context, obj: JSValue, name: cstring, v: JSValue) -> bool ---

	// the realm's singletons, impls, marks
	web_singleton :: proc(ctx: ^Context, which: i32, make: Singleton_Make) -> JSValue ---
	web_set_impl  :: proc(obj: JSValue, impl: rawptr, impl_free: Impl_Free, impl_mark: Impl_Mark) ---
	web_pin       :: proc(ctx: ^Context, v: JSValue) -> u32 ---
	web_unpin     :: proc(ctx: ^Context, token: u32) ---
	web_unpin_later :: proc(ctx: ^Context, token: u32) ---

	// events
	wj_event_construct :: proc(ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue, iface: i32, name: cstring) -> JSValue ---
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
	web_iter_result  :: proc(ctx: ^Context, value: JSValue, done: bool) -> JSValue ---

	// queued tasks
	web_queue_task   :: proc(ctx: ^Context, fn: Task_Fn, data: JSValue) -> bool ---
}

// web_rt() is `static inline` in web.h (JS_GetRuntime(wj_the_realm.ctx)): no symbol, so it is reimplemented here.
web_rt :: #force_inline proc "contextless" () -> ^Runtime { return JS_GetRuntime(realm_ctx()) }

// web.h iterator kinds and iterable ids.
ITER_KEYS    :: i32(0)
ITER_VALUES  :: i32(1)
ITER_ENTRIES :: i32(2)

ITERABLE_HEADERS         :: i32(0)
ITERABLE_URLSEARCHPARAMS :: i32(1)
ITERABLE_FORMDATA        :: i32(2)

// web.h singleton ids (WEB_SINGLE_*).
SINGLE_LOCATION        :: i32(0)
SINGLE_HISTORY         :: i32(1)
SINGLE_NAVIGATOR       :: i32(2)
SINGLE_LOCAL_STORAGE   :: i32(3)
SINGLE_SESSION_STORAGE :: i32(4)
SINGLE_PERFORMANCE     :: i32(5)
SINGLE_CRYPTO          :: i32(6)
SINGLE_SUBTLE          :: i32(7)
SINGLE_SCREEN          :: i32(8)
SINGLE_CREDENTIALS     :: i32(9)
SINGLE_CLIPBOARD       :: i32(10)
SINGLE_VISUAL_VIEWPORT :: i32(11)
SINGLE_PERMISSIONS     :: i32(12)
SINGLE_FONTS           :: i32(13)
SINGLE_CACHES          :: i32(14)
SINGLE_SERVICE_WORKER  :: i32(15)
SINGLE_STORAGE         :: i32(16)
SINGLE_TIMELINE        :: i32(17)

// The engine's EventInit base dictionary (bindings.h): the common Event members. Ported event dictionaries that embed
// it (PageTransitionEventInit...) mirror it as their first field, matching the C struct layout.
Event_Init :: struct {
	bubbles:    bool,
	cancelable: bool,
	composed:   bool,
}

// ---- the C field accessors of wj_shim.c (fields of global C structs: wj_the_realm, wj_obj) ----

@(default_calling_convention = "c")
foreign {
	wj_realm_global :: proc() -> JSValue ---          // wj_the_realm.global (not counted)
	wj_realm_ctx    :: proc() -> ^Context ---         // wj_the_realm.ctx
	wj_realm_kind   :: proc() -> i32 ---              // wj_the_realm.kind
	wj_realm_proto  :: proc(iface: i32) -> JSValue --- // wj_the_realm.protos[iface]

	// the two leading fields of a wj_obj (off a JSValue, or off a wj_obj* wj_this/wj_unwrap returned)
	wj_shim_obj_handle :: proc(v: JSValue) -> u64 ---
	wj_shim_obj_impl   :: proc(v: JSValue) -> rawptr ---
	wj_shim_handle     :: proc(obj: rawptr) -> u64 ---
	wj_shim_impl       :: proc(obj: rawptr) -> rawptr ---
}

// The realm's global object (not counted). Matches web_strategy.c's use of wj_the_realm.global.
realm_global :: #force_inline proc "contextless" () -> JSValue { return wj_realm_global() }
realm_ctx    :: #force_inline proc "contextless" () -> ^Context { return wj_realm_ctx() }
realm_kind   :: #force_inline proc "contextless" () -> i32 { return wj_realm_kind() }
realm_proto  :: #force_inline proc "contextless" (iface: i32) -> JSValue { return wj_realm_proto(iface) }
proto_of     :: realm_proto

// web_is_window(): the realm's kind is not a worker (WJ_EXPOSE_WORKER == 1<<1 == 2, per wj.h).
EXPOSE_WORKER :: i32(1 << 1)
is_window :: #force_inline proc "contextless" () -> bool { return realm_kind() != EXPOSE_WORKER }

// The browser handle / impl behind a platform object `v` (0/nil when none). Same as reading wj_obj_of(v)->handle.
obj_handle :: #force_inline proc "contextless" (v: JSValue) -> u64 { return wj_shim_obj_handle(v) }
obj_impl   :: #force_inline proc "contextless" (v: JSValue) -> rawptr { return wj_shim_obj_impl(v) }
// The handle / impl off a wj_obj* (what wj_this / wj_unwrap return).
handle_of  :: #force_inline proc "contextless" (obj: rawptr) -> u64 { return wj_shim_handle(obj) }
impl_of    :: #force_inline proc "contextless" (obj: rawptr) -> rawptr { return wj_shim_impl(obj) }

// web_this_impl is declared above; this_impl mirrors the C name used across runtime/web.
this_impl :: #force_inline proc "contextless" (ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr {
	return web_this_impl(ctx, this_val, iface)
}
