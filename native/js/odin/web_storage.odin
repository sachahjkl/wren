// web_storage.odin: localStorage and sessionStorage (HTML Web Storage) on the browser's stores (module storage), and
// StorageEvent. Ported from native/js/runtime/web_storage.c; behaviour and the wjr_* symbols are identical.
//
// Storage objects are "legacy platform objects" with named properties: localStorage.foo reads getItem("foo") (unless
// the prototype has foo), localStorage.foo = v is setItem, delete localStorage.foo is removeItem, Object.keys lists the
// keys in order. An opaque origin or disabled storage makes the getter throw a SecurityError; a write past the quota
// throws a QuotaExceededError. Each call goes to the browser (the store is shared with the origin's other pages).
package odin_glue

import "../odin/wj"

foreign import m_storage "storage"

@(default_calling_convention = "c")
foreign m_storage {
	@(link_name = "Storage_length")     wr_Storage_length     :: proc(area: i32, ret: ^i32) -> i32 ---
	@(link_name = "Storage_key")        wr_Storage_key        :: proc(area: i32, index: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Storage_getItem")    wr_Storage_getItem    :: proc(area: i32, key: [^]u8, key_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Storage_setItem")    wr_Storage_setItem    :: proc(area: i32, key: [^]u8, key_len: u32, value: [^]u8, value_len: u32) -> i32 ---
	@(link_name = "Storage_removeItem") wr_Storage_removeItem :: proc(area: i32, key: [^]u8, key_len: u32) -> i32 ---
	@(link_name = "Storage_clear")      wr_Storage_clear      :: proc(area: i32) -> i32 ---
	@(link_name = "StorageEvent_get")         wr_StorageEvent_get         :: proc(event: u64, field: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "StorageEvent_storageArea") wr_StorageEvent_storageArea :: proc(event: u64, ret: ^i32) -> i32 ---
}

STORAGE_AREA_LOCAL   :: i32(0)   // wr_StorageArea_Local
STORAGE_AREA_SESSION :: i32(1)   // wr_StorageArea_Session
ERR_NOT_FOUND :: i32(-3)         // wr_Error_Not_Found
ERR_QUOTA     :: i32(-13)        // wr_Error_Quota

Storage_Impl :: struct {
	area: i32,
}

// Interface indices resolved once by name (robust against table renumbering), like web_strategy.odin.
@(private = "file") iface_storage := i32(-2)
@(private = "file") iface_storage_event := i32(-2)

@(private = "file")
storage_iface :: proc "c" () -> i32 {
	if iface_storage == -2 { iface_storage = wj.iface("Storage") }
	return iface_storage
}
@(private = "file")
storage_event_iface :: proc "c" () -> i32 {
	if iface_storage_event == -2 { iface_storage_event = wj.iface("StorageEvent") }
	return iface_storage_event
}

@(private = "file")
storage_free :: proc "c" (p: rawptr) { wj.free(p) }

@(private = "file")
storage_make :: proc "c" (ctx: ^wj.Context, area: i32) -> wj.JSValue {
	s := (^Storage_Impl)(wj.malloc(size_of(Storage_Impl)))
	if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	s.area = area
	return wj.wj_new_object(ctx, storage_iface(), s, storage_free)
}

@(private = "file") make_local   :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return storage_make(ctx, STORAGE_AREA_LOCAL) }
@(private = "file") make_session :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return storage_make(ctx, STORAGE_AREA_SESSION) }

// SecurityError until the document may use this storage (then the object is the document's for good, as in browsers;
// each call still fails if the storage is disabled meanwhile).
@(private = "file") storage_allowed: [2]bool

@(private = "file")
storage_getter :: proc "c" (ctx: ^wj.Context, area: i32) -> wj.JSValue {
	if !storage_allowed[area] {
		n := i32(0)
		st := wr_Storage_length(area, &n)
		if st < 0 { return wj.wj_throw_status(ctx, st, area == STORAGE_AREA_LOCAL ? "localStorage" : "sessionStorage") }
		storage_allowed[area] = true
	}
	which := area == STORAGE_AREA_LOCAL ? wj.SINGLE_LOCAL_STORAGE : wj.SINGLE_SESSION_STORAGE
	return wj.web_singleton(ctx, which, area == STORAGE_AREA_LOCAL ? make_local : make_session)
}

@(export, link_name = "wjr_WindowLocalStorage_get_localStorage")
wjr_WindowLocalStorage_get_localStorage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return storage_getter(ctx, STORAGE_AREA_LOCAL)
}

@(export, link_name = "wjr_WindowSessionStorage_get_sessionStorage")
wjr_WindowSessionStorage_get_sessionStorage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return storage_getter(ctx, STORAGE_AREA_SESSION)
}

@(private = "file")
storage_this :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Storage_Impl {
	return (^Storage_Impl)(wj.web_this_impl(ctx, this_val, storage_iface()))
}

@(private = "file")
storage_obj :: proc "c" (v: wj.JSValue) -> ^Storage_Impl {
	return (^Storage_Impl)(wj.impl_of(wj.wj_unwrap(v, storage_iface())))
}

@(export, link_name = "wjr_Storage_get_length")
wjr_Storage_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	s := storage_this(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	n := i32(0)
	st := wr_Storage_length(s.area, &n)
	if st < 0 { return wj.wj_throw_status(ctx, st, "Storage.length") }
	return wj.new_int32(n)
}

// Operands of the browser string calls (what WJ_FETCH_STRING captured lexically in C; here passed explicitly through
// wj.fetch_string so the two-call grow loop stays re-entrancy-safe).
@(private = "file") Get_Item_Op :: struct { area: i32, key: []u8 }
@(private = "file") Key_Op      :: struct { area: i32, index: i32 }

@(private = "file")
fill_get_item :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Get_Item_Op)(user)
	return wr_Storage_getItem(op.area, raw_data(op.key), u32(len(op.key)), buf, cap)
}
@(private = "file")
fill_key :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Key_Op)(user)
	return wr_Storage_key(op.area, op.index, buf, cap)
}

// getItem: the value, NULL when absent; EXCEPTION on an error.
@(private = "file")
get_item :: proc "c" (ctx: ^wj.Context, area: i32, key: []u8) -> wj.JSValue {
	op := Get_Item_Op{ area, key }
	n := wj.fetch_string(fill_get_item, &op)
	if n == ERR_NOT_FOUND { return wj.NULL }
	if n < 0 { return wj.wj_throw_status(ctx, n, "Storage.getItem") }
	return wj.new_string_len(ctx, wj.scratch_bytes(n))
}

@(export, link_name = "wjr_Storage_key")
wjr_Storage_key :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := storage_this(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Storage.key", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	if i > 0x7FFF_FFFF { return wj.NULL }
	op := Key_Op{ s.area, i32(i) }
	n := wj.fetch_string(fill_key, &op)
	if n == ERR_NOT_FOUND { return wj.NULL }
	if n < 0 { return wj.wj_throw_status(ctx, n, "Storage.key") }
	return wj.new_string_len(ctx, wj.scratch_bytes(n))
}

@(export, link_name = "wjr_Storage_getItem")
wjr_Storage_getItem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := storage_this(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Storage.getItem", 1, argc) }
	k: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &k, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &k)
	return get_item(ctx, s.area, wj.str_slice(k))
}

// set_item: 0 on success, -1 with an exception pending.
@(private = "file")
set_item :: proc "c" (ctx: ^wj.Context, area: i32, key: wj.JSValue, value: wj.JSValue) -> i32 {
	k, v: wj.Str
	if !wj.web_to_usv(ctx, key, &k) { return -1 }
	defer wj.wj_str_free(ctx, &k)
	if !wj.web_to_usv(ctx, value, &v) { return -1 }
	defer wj.wj_str_free(ctx, &v)
	st := wr_Storage_setItem(area, k.ptr, u32(k.len), v.ptr, u32(v.len))
	if st < 0 {
		if st == ERR_QUOTA {
			wj.wj_throw_dom(ctx, "QuotaExceededError", "Failed to execute 'setItem' on 'Storage': Setting the value exceeded the quota.")
		} else {
			wj.wj_throw_status(ctx, st, "Storage.setItem")
		}
		return -1
	}
	return 0
}

@(export, link_name = "wjr_Storage_setItem")
wjr_Storage_setItem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := storage_this(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Storage.setItem", 2, argc) }
	return set_item(ctx, s.area, argv[0], argv[1]) < 0 ? wj.EXCEPTION : wj.UNDEFINED
}

@(export, link_name = "wjr_Storage_removeItem")
wjr_Storage_removeItem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := storage_this(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Storage.removeItem", 1, argc) }
	k: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &k, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &k)
	st := wr_Storage_removeItem(s.area, k.ptr, u32(k.len))
	if st < 0 { return wj.wj_throw_status(ctx, st, "Storage.removeItem") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Storage_clear")
wjr_Storage_clear :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := storage_this(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	st := wr_Storage_clear(s.area)
	if st < 0 { return wj.wj_throw_status(ctx, st, "Storage.clear") }
	return wj.UNDEFINED
}

// ---- named properties ----

@(export, link_name = "wjr_Storage_named_get")
wjr_Storage_named_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, len: uint, found: ^bool) -> wj.JSValue {
	s := storage_obj(obj)
	found^ = false
	if s == nil { return wj.UNDEFINED }
	v := get_item(ctx, s.area, name[:len])
	if wj.is_exception(v) { return v }
	if wj.is_null(v) { return wj.UNDEFINED }
	found^ = true
	return v
}

@(export, link_name = "wjr_Storage_named_set")
wjr_Storage_named_set :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, len: uint, value: wj.JSValue) -> i32 {
	s := storage_obj(obj)
	if s == nil { return 0 }
	key := wj.new_string_len(ctx, name[:len])
	r := set_item(ctx, s.area, key, value)
	wj.JS_FreeValue(ctx, key)
	return r
}

@(export, link_name = "wjr_Storage_named_delete")
wjr_Storage_named_delete :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, len: uint) -> i32 {
	s := storage_obj(obj)
	if s == nil { return 0 }
	st := wr_Storage_removeItem(s.area, name, u32(len))
	if st < 0 { wj.wj_throw_status(ctx, st, "Storage.removeItem"); return -1 }
	return 1
}

@(export, link_name = "wjr_Storage_named_keys")
wjr_Storage_named_keys :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, array: wj.JSValue) -> i32 {
	s := storage_obj(obj)
	if s == nil { return 0 }
	n := i32(0)
	if wr_Storage_length(s.area, &n) < 0 { return 0 }
	for i in 0 ..< n {
		op := Key_Op{ s.area, i }
		l := wj.fetch_string(fill_key, &op)
		if l < 0 { break }
		wj.array_set(ctx, array, u32(i), wj.new_string_len(ctx, wj.scratch_bytes(l)))
	}
	return 0
}

// ---- StorageEvent ----

@(private = "file") storage_fields := [4]cstring{ "key", "oldValue", "newValue", "url" }

@(private = "file") Event_Op :: struct { event: u64, field: i32 }

@(private = "file")
fill_event :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Event_Op)(user)
	return wr_StorageEvent_get(op.event, op.field, buf, cap)
}

// The fields of a browser storage event, read once while it is dispatched.
@(private = "file")
storage_snapshot :: proc "c" (ctx: ^wj.Context, ev: wj.JSValue) {
	have := wj.web_extra_get(ctx, ev, "url")
	done := !wj.is_undefined(have)
	wj.JS_FreeValue(ctx, have)
	h := wj.web_event_host(ev)
	if done || h == 0 { return }
	for f in 0 ..< i32(4) {
		op := Event_Op{ h, f }
		n := wj.fetch_string(fill_event, &op)
		v := n == ERR_NOT_FOUND ? wj.NULL : wj.new_string_len(ctx, wj.scratch_bytes(n))
		wj.web_extra_set(ctx, ev, storage_fields[f], v)
	}
	area := i32(0)
	if wr_StorageEvent_storageArea(h, &area) >= 0 {
		which := area == STORAGE_AREA_LOCAL ? wj.SINGLE_LOCAL_STORAGE : wj.SINGLE_SESSION_STORAGE
		s := wj.web_singleton(ctx, which, area == STORAGE_AREA_LOCAL ? make_local : make_session)
		wj.web_extra_set(ctx, ev, "storageArea", s)
	}
}

@(private = "file")
storage_event_field :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, def: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, storage_event_iface()) == nil { return wj.EXCEPTION }
	storage_snapshot(ctx, this_val)
	v := wj.web_extra_get(ctx, this_val, name)
	if wj.is_undefined(v) { return def }
	wj.JS_FreeValue(ctx, def)
	return v
}

@(export, link_name = "wjr_StorageEvent_get_key")
wjr_StorageEvent_get_key :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return storage_event_field(ctx, t, "key", wj.NULL) }
@(export, link_name = "wjr_StorageEvent_get_oldValue")
wjr_StorageEvent_get_oldValue :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return storage_event_field(ctx, t, "oldValue", wj.NULL) }
@(export, link_name = "wjr_StorageEvent_get_newValue")
wjr_StorageEvent_get_newValue :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return storage_event_field(ctx, t, "newValue", wj.NULL) }
@(export, link_name = "wjr_StorageEvent_get_url")
wjr_StorageEvent_get_url :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return storage_event_field(ctx, t, "url", wj.new_cstring(ctx, "")) }
@(export, link_name = "wjr_StorageEvent_get_storageArea")
wjr_StorageEvent_get_storageArea :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return storage_event_field(ctx, t, "storageArea", wj.NULL) }

@(private = "file")
storage_init_fields :: proc "c" (ctx: ^wj.Context, ev: wj.JSValue, init: wj.JSValue) -> bool {
	for f in 0 ..< i32(4) {
		v: wj.JSValue
		if !wj.web_dict_get(ctx, init, storage_fields[f], &v) { return false }
		if wj.is_undefined(v) {
			v = f == 3 ? wj.new_cstring(ctx, "") : wj.NULL
		} else if !wj.is_null(v) || f == 3 {
			s := wj.JS_ToString(ctx, v)
			wj.JS_FreeValue(ctx, v)
			if wj.is_exception(s) { return false }
			v = s
		}
		wj.web_extra_set(ctx, ev, storage_fields[f], v)
	}
	area: wj.JSValue
	if !wj.web_dict_get(ctx, init, "storageArea", &area) { return false }
	if !wj.is_undefined(area) && !wj.is_null(area) && storage_obj(area) == nil {
		wj.JS_FreeValue(ctx, area)
		wj.wj_throw_type(ctx, "Failed to construct 'StorageEvent': member storageArea is not of type Storage.")
		return false
	}
	wj.web_extra_set(ctx, ev, "storageArea", wj.is_undefined(area) ? wj.NULL : area)
	return true
}

@(export, link_name = "wjr_StorageEvent_constructor")
wjr_StorageEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, storage_event_iface(), "StorageEvent")
	if wj.is_exception(ev) { return ev }
	if !storage_init_fields(ctx, ev, wj.arg(argc, argv, 1)) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	return ev
}
