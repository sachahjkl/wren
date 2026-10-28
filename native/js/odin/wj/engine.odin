// engine.odin: the engine's own C structs and globals (native/js/engine/wj.h, qjs_internal.h), mirrored field for
// field so a ported domain reads and writes them in place, and the `static inline` helpers over them (wj_obj_of,
// web_set_impl, web_is_window) reimplemented. One declaration per symbol.
//
// Why mirrors and not C accessors: a field of a global struct has no symbol, so the first ports read wj_the_realm and
// wj_obj through one-line C accessors (wj_shim.c). That was C written by us for every field, and a call per read. The
// layouts are plain wasm32 C (natural alignment, no bitfields, no unions), so Odin's default struct layout reproduces
// them exactly; native/js/odin/wj_shim.c pins each mirrored offset and size with _Static_assert, so a change on the C
// side breaks the build instead of corrupting memory. When a struct moves to Odin, its mirror becomes the definition
// and its asserts go.
package wj

// ---- wj.h: the interface table ----

// wj_interface. The function pointers are only ever called by the engine; they are mirrored as rawptr to keep the
// layout (and the stride of wj_interfaces[]) exact.
Interface :: struct {
	name:           cstring,
	parent:         i16,      // index in wj_interfaces, -1 for none
	exposed:        u16,      // EXPOSE_*
	flags:          u16,      // WJ_I_*
	class_kind:     u8,       // WJ_CLASS_*
	ctor_length:    u16,
	ctor:           rawptr,
	members:        rawptr,
	n_members:      u16,
	subtree_end:    u16,      // interfaces [index, subtree_end) inherit from this one (pre-order)
	index_get:      rawptr,
	length_get:     rawptr,
	named_get:      rawptr,
	named_set:      rawptr,
	named_delete:   rawptr,
	named_keys:     rawptr,
	legacy_alias:   cstring,
	factory_name:   cstring,
	factory:        rawptr,
	factory_length: u16,
}

// ---- wj.h: platform objects ----

// wj_listener: an event listener or handler registered from JavaScript on a platform object.
Listener :: struct {
	next:     ^Listener,
	callback: JSValue,   // counted
	type:     JSValue,   // counted
	host_id:  i32,
	slot:     u32,
	capture:  u8,
	once:     u8,
	passive:  u8,
	handler:  u8,        // 1 plain, 2 OnErrorEventHandler, 3 OnBeforeUnload
	owner:    ^Obj,
}

Impl_Free :: #type proc "c" (p: rawptr)
Impl_Mark :: #type proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr)

// wj_obj: the platform object behind a JS wrapper.
Obj :: struct {
	handle:     u64,       // the browser's object; 0 for objects only the engine has
	iface:      u16,       // index in wj_interfaces
	kind:       u8,        // KIND_*
	flags:      u8,        // OBJ_*
	group_slot: u32,
	group:      rawptr,    // wj_group *, opaque
	group_val:  JSValue,
	listeners:  ^Listener,
	impl:       rawptr,    // data of interfaces implemented in the engine
	impl_free:  Impl_Free,
	impl_mark:  Impl_Mark,
	self:       JSValue,   // the wrapper itself (not counted)
	same:       [^]JSValue,
	n_same:     u16,
}

KIND_NONE   :: 0
KIND_NODE   :: 1
KIND_HOST   :: 2
KIND_GLOBAL :: 3

OBJ_OWNED :: 1 << 0

// What an interface is exposed to / the kind of a realm (WJ_EXPOSE_*).
EXPOSE_WINDOW         :: i32(1 << 0)
EXPOSE_WORKER         :: i32(1 << 1)
EXPOSE_SHARED_WORKER  :: i32(1 << 2)
EXPOSE_SERVICE_WORKER :: i32(1 << 3)
EXPOSE_ANY_WORKER     :: EXPOSE_WORKER | EXPOSE_SHARED_WORKER | EXPOSE_SERVICE_WORKER

// ---- wj.h: the realm ----

// wj_realm.
Realm :: struct {
	ctx:            ^Context,
	kind:           i32,         // EXPOSE_WINDOW or EXPOSE_WORKER (any kind of worker)
	scope:          i32,         // one EXPOSE_* bit: what the global exposes
	global_obj:     Obj,
	global:         JSValue,
	protos:         [^]JSValue,  // per interface: prototype object
	ctors:          [^]JSValue,  // per interface: interface object (or undefined)
	started:        bool,
	in_gc_prologue: bool,
}

// wj_buf: the per-realm scratch buffer browser string results are written into.
Buf :: struct {
	data: [^]u8,
	cap:  u32,
}

// ---- the engine's globals ----
// wj_the_realm and wj_scratch are defined in qjs_realm.odin, the platform classes (wj_class_*) in qjs_platform.odin.
// A global defined by C stays `foreign` here; one defined in Odin must not also be declared `foreign` in any package
// (the build is one LLVM module: the second declaration is renamed and never resolves).

@(default_calling_convention = "c")
foreign {
	// `extern const wj_interface wj_interfaces[]`: an array symbol, so its first element is what the name designates;
	// interfaces() gives the indexable view.
	wj_interfaces:       Interface
	wj_interface_count:  i32
}
// (wj_dispatch_trusted, web.h: defined by the event layer, native/js/odin/events.odin)

interfaces :: #force_inline proc "contextless" () -> [^]Interface { return ([^]Interface)(&wj_interfaces) }

// ---- the realm (wj_the_realm), read in place ----

realm_global :: #force_inline proc "contextless" () -> JSValue { return wj_the_realm.global }   // not counted
realm_ctx    :: #force_inline proc "contextless" () -> ^Context { return wj_the_realm.ctx }
realm_kind   :: #force_inline proc "contextless" () -> i32 { return wj_the_realm.kind }
realm_proto  :: #force_inline proc "contextless" (iface: i32) -> JSValue { return wj_the_realm.protos[iface] }   // not counted

// web_rt() (web.h, static inline): the realm's runtime.
web_rt :: #force_inline proc "contextless" () -> ^Runtime { return JS_GetRuntime(wj_the_realm.ctx) }

// web_is_window() (web.h, static inline): the realm is a document's, not any worker's.
is_window :: #force_inline proc "contextless" () -> bool { return wj_the_realm.kind != EXPOSE_WORKER }

// ---- platform objects (the static inlines of qjs_internal.h / web.h) ----

// wj_obj_of: the wj_obj of any platform object (any platform class), or nil.
obj_of :: proc "contextless" (v: JSValue) -> ^Obj {
	if !is_object(v) { return nil }
	id := JS_GetClassID(v)
	if id != wj_class_plain && id != wj_class_indexed && id != wj_class_named { return nil }
	return (^Obj)(JS_GetOpaque(v, id))
}

// The browser handle / engine-owned data behind a platform object `v` (0 / nil when none).
obj_handle :: #force_inline proc "contextless" (v: JSValue) -> u64 { o := obj_of(v); return o != nil ? o.handle : 0 }
obj_impl   :: #force_inline proc "contextless" (v: JSValue) -> rawptr { o := obj_of(v); return o != nil ? o.impl : nil }

// The handle / impl off a wj_obj (what wj_this / wj_unwrap return), nil-safe.
handle_of :: #force_inline proc "contextless" (o: ^Obj) -> u64 { return o != nil ? o.handle : 0 }
impl_of   :: #force_inline proc "contextless" (o: ^Obj) -> rawptr { return o != nil ? o.impl : nil }

// ---- layout: the same numbers native/js/odin/wj_shim.c asserts on the C side ----

#assert(size_of(Interface) == 68 && offset_of(Interface, subtree_end) == 26 && offset_of(Interface, factory_length) == 64)
#assert(size_of(Listener) == 40 && offset_of(Listener, callback) == 8 && offset_of(Listener, owner) == 36)
#assert(size_of(Obj) == 64 && offset_of(Obj, group_val) == 24 && offset_of(Obj, impl) == 36 && offset_of(Obj, self) == 48 && offset_of(Obj, n_same) == 60)
#assert(size_of(Realm) == 104 && offset_of(Realm, global_obj) == 16 && offset_of(Realm, global) == 80 && offset_of(Realm, protos) == 88 && offset_of(Realm, in_gc_prologue) == 97)
#assert(size_of(Buf) == 8 && size_of(Str) == 12 && offset_of(Str, owned) == 8)
#assert(size_of(Dom_Impl) == 96 && offset_of(Dom_Impl, rect) == 56 && offset_of(Dom_Impl, values) == 88)
#assert(size_of(Extracted) == 24 && offset_of(Extracted, stream) == 16)

// web_set_impl (web.h, static inline): a platform object's engine-owned data, how to free it and how to mark the JS
// values it holds.
web_set_impl :: proc "contextless" (obj: JSValue, impl: rawptr, impl_free: Impl_Free, impl_mark: Impl_Mark) {
	o := obj_of(obj)
	if o == nil { return }
	o.impl = impl
	o.impl_free = impl_free
	o.impl_mark = impl_mark
}
