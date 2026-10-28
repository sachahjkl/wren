// host.odin: what a ported domain calls of the engine (wj.h / qjs_internal.h) and of the runtime (web.h) that is not a
// value or a string helper: the engine's malloc, the interface table, platform objects and wrappers, the realm's
// singletons, dictionaries, iterators, events, queued tasks. They are implemented in Odin in this package
// (qjs_realm.odin, qjs_platform.odin, web_core.odin) under their C names; what stays C is declared here. The browser's
// own imports (wr_*) are not here: they are generated (wr_imports.odin).
package wj

@(default_calling_convention = "c")
foreign {
	// runtime/events.c: an Event object of `iface` made as `new Event(type, init)` would (new_target: its constructor)
}

// Resolve an interface index by name (cache it in the caller if hot). -1 when unknown.
iface :: #force_inline proc "contextless" (name: cstring) -> i32 { return wj_interface_find(name) }

malloc :: #force_inline proc "contextless" (n: uint) -> rawptr { return wj_malloc(n) }
free   :: #force_inline proc "contextless" (p: rawptr) { wj_free(p) }

// The function-table index of an exported callback (wasm32: a function pointer is its table index), for the
// `callback` argument of a wr_* import (Timers_setTimeout64, ResizeObserver_create...).
table_index :: #force_inline proc "contextless" (fn: rawptr) -> i32 { return i32(uintptr(fn)) }

// ---- the realm's singletons, dictionaries, events, iterators, tasks (web.h; web_core.odin) ----

Singleton_Make :: #type proc "c" (ctx: ^Context) -> JSValue
Task_Fn        :: #type proc "c" (ctx: ^Context, data: JSValue)
Pair_At        :: #type proc "c" (ctx: ^Context, owner: JSValue, index: u32, key: ^JSValue, value: ^JSValue) -> i32
For_Of_Fn      :: #type proc "c" (ctx: ^Context, item: JSValue, opaque: rawptr) -> bool
For_Record_Fn  :: #type proc "c" (ctx: ^Context, key: JSValue, value: JSValue, opaque: rawptr) -> bool

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
