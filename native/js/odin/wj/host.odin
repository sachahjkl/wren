// host.odin: the functions of the engine (native/js/engine, wj.h / qjs_internal.h) and of the runtime C that stays
// (native/js/runtime, web.h) a ported domain calls: the engine's malloc, the interface table, platform objects and
// wrappers, the realm's singletons, dictionaries, iterators, events, queued tasks. Real symbols, one declaration each.
// The browser's own imports (wr_*) are not here: they are generated (wr_imports.odin).
package wj

// ---- the engine's malloc and the interface table ----

@(default_calling_convention = "c")
foreign {
	// index of an interface by name in the generated table, -1 when unknown (avoids hardcoding WJ_IFACE_* numbers)
	wj_interface_find :: proc(name: cstring) -> i32 ---
	// the realm's shared scratch allocator (the engine's malloc)
	wj_malloc :: proc(n: uint) -> rawptr ---
	wj_free   :: proc(p: rawptr) ---
}

// Resolve an interface index by name (cache it in the caller if hot). -1 when unknown.
iface :: #force_inline proc "contextless" (name: cstring) -> i32 { return wj_interface_find(name) }

malloc :: #force_inline proc "contextless" (n: uint) -> rawptr { return wj_malloc(n) }
free   :: #force_inline proc "contextless" (p: rawptr) { wj_free(p) }

// ---- platform objects and wrappers ----

@(default_calling_convention = "c")
foreign {
	// `this` of an operation / attribute of `iface`: nil with a TypeError ("Illegal invocation") pending otherwise
	wj_this           :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> ^Obj ---
	// the platform object behind `v` when it implements `iface` (or a descendant), else nil (no exception)
	wj_unwrap         :: proc(v: JSValue, iface: i32) -> ^Obj ---
	// the impl of `this` when it is a platform object of `iface` made by the engine (nil + TypeError otherwise)
	web_this_impl     :: proc(ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr ---
	wj_wrap_node      :: proc(ctx: ^Context, node: u64) -> JSValue ---
	wj_wrap_host      :: proc(ctx: ^Context, handle: u64, iface: i32) -> JSValue ---
	wj_cached         :: proc(ctx: ^Context, handle: u64) -> JSValue ---
	wj_wrap_owned     :: proc(ctx: ^Context, handle: u64, iface: i32, new_target: JSValue) -> JSValue ---
	wj_new_object     :: proc(ctx: ^Context, iface: i32, impl: rawptr, impl_free: Impl_Free) -> JSValue ---
	wj_new_object_for :: proc(ctx: ^Context, iface: i32, new_target: JSValue, impl: rawptr, impl_free: Impl_Free) -> JSValue ---
	wj_mark           :: proc(rt: rawptr, v: JSValue, mark_func: rawptr) ---

	// reporting, stack budget, the console sink, CSP for string handlers, the script name for stack traces
	wj_report_exception   :: proc(ctx: ^Context, exc: JSValue) ---
	wj_report_pending     :: proc(ctx: ^Context) ---
	wj_stack_enter        :: proc(ctx: ^Context) ---
	wj_console_text       :: proc(level: i32, text: [^]u8, len: uint) ---
	wj_can_compile_string :: proc(ctx: ^Context, source: JSValue) -> bool ---
	wj_script_base_name   :: proc(out: [^]u8, cap: uint) -> uint ---
}

// The function-table index of an exported callback (wasm32: a function pointer is its table index), for the
// `callback` argument of a wr_* import (Timers_setTimeout64, ResizeObserver_create...).
table_index :: #force_inline proc "contextless" (fn: rawptr) -> i32 { return i32(uintptr(fn)) }

// web_this_impl under the name the runtime reads it.
this_impl :: #force_inline proc "contextless" (ctx: ^Context, this_val: JSValue, iface: i32) -> rawptr {
	return web_this_impl(ctx, this_val, iface)
}

// ---- the realm's singletons, dictionaries, events, iterators, tasks (web.h) ----

Singleton_Make :: #type proc "c" (ctx: ^Context) -> JSValue
Task_Fn        :: #type proc "c" (ctx: ^Context, data: JSValue)
Pair_At        :: #type proc "c" (ctx: ^Context, owner: JSValue, index: u32, key: ^JSValue, value: ^JSValue) -> i32
For_Of_Fn      :: #type proc "c" (ctx: ^Context, item: JSValue, opaque: rawptr) -> bool
For_Record_Fn  :: #type proc "c" (ctx: ^Context, key: JSValue, value: JSValue, opaque: rawptr) -> bool

@(default_calling_convention = "c")
foreign {
	// dictionaries, freeze, hidden state
	web_freeze     :: proc(ctx: ^Context, v: JSValue) -> bool ---
	web_dict_check :: proc(ctx: ^Context, dict: JSValue, what: cstring) -> bool ---
	web_dict_get   :: proc(ctx: ^Context, dict: JSValue, name: cstring, out: ^JSValue) -> bool ---
	web_extra      :: proc(ctx: ^Context, obj: JSValue, create: bool) -> JSValue ---
	web_extra_get  :: proc(ctx: ^Context, obj: JSValue, name: cstring) -> JSValue ---
	web_extra_set  :: proc(ctx: ^Context, obj: JSValue, name: cstring, v: JSValue) -> bool ---

	// the realm's singletons, pins
	web_singleton   :: proc(ctx: ^Context, which: i32, make: Singleton_Make) -> JSValue ---
	web_pin         :: proc(ctx: ^Context, v: JSValue) -> u32 ---
	web_unpin       :: proc(ctx: ^Context, token: u32) ---
	web_unpin_later :: proc(ctx: ^Context, token: u32) ---

	// events
	wj_event_construct :: proc(ctx: ^Context, new_target: JSValue, argc: i32, argv: [^]JSValue, iface: i32, name: cstring) -> JSValue ---
	web_event_host  :: proc(ev: JSValue) -> u64 ---
	web_event_new   :: proc(ctx: ^Context, iface: i32, type: cstring, bubbles: bool, cancelable: bool) -> JSValue ---
	web_event_fire  :: proc(ctx: ^Context, target: JSValue, ev: JSValue) -> bool ---
	web_fire_simple :: proc(ctx: ^Context, target: JSValue, type: cstring) -> bool ---

	// iterators of pair iterables, sequences, records
	web_iterator_new :: proc(ctx: ^Context, iterable: i32, owner: JSValue, kind: i32, at: Pair_At) -> JSValue ---
	web_for_each     :: proc(ctx: ^Context, owner: JSValue, argc: i32, argv: [^]JSValue, at: Pair_At) -> JSValue ---
	web_is_iterable  :: proc(ctx: ^Context, v: JSValue) -> i32 ---
	web_for_of       :: proc(ctx: ^Context, iterable: JSValue, fn: For_Of_Fn, opaque: rawptr) -> bool ---
	web_for_record   :: proc(ctx: ^Context, obj: JSValue, fn: For_Record_Fn, opaque: rawptr) -> bool ---
	web_iter_result  :: proc(ctx: ^Context, value: JSValue, done: bool) -> JSValue ---

	// queued tasks
	web_queue_task :: proc(ctx: ^Context, fn: Task_Fn, data: JSValue) -> bool ---
}

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
