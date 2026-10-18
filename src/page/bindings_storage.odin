package page

// localStorage / sessionStorage (Web Storage; import module "storage"). `kind` is 0 for localStorage, 1 for
// sessionStorage. Null results are Not_Found; an opaque origin or disabled storage is WEB_ERR_SECURITY; a write past the
// quota is WEB_ERR_QUOTA. The store itself is storage.odin.

import "wb:dom"
import "wb:wasm"

@(private)
storage_kind :: proc "contextless" (k: i32) -> (Storage_Kind, bool) {
	switch k {
	case 0: return .Local, true
	case 1: return .Session, true
	}
	return .Local, false
}

n_Storage_length :: proc "c" (env: wasm.Exec_Env, kind: i32) -> i32 {
	context = ctx()
	k, ok := storage_kind(kind)
	if !ok { return i32(dom.Error.Invalid_Argument) }
	n, err := storage_length(page_of(env), k)
	if err != 0 { return err }
	return i32(n)
}

n_Storage_key :: proc "c" (env: wasm.Exec_Env, kind: i32, index: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	k, ok := storage_kind(kind)
	if !ok { return i32(dom.Error.Invalid_Argument) }
	key, found, err := storage_key(page_of(env), k, int(index))
	if err != 0 { return err }
	if !found { return i32(dom.Error.Not_Found) }
	return out_string(key, buf, cap)
}

n_Storage_getItem :: proc "c" (env: wasm.Exec_Env, kind: i32, key: [^]u8, kl: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	k, ok := storage_kind(kind)
	if !ok { return i32(dom.Error.Invalid_Argument) }
	v, found, err := storage_get_item(page_of(env), k, str(key, kl))
	if err != 0 { return err }
	if !found { return i32(dom.Error.Not_Found) }
	return out_string(v, buf, cap)
}

n_Storage_setItem :: proc "c" (env: wasm.Exec_Env, kind: i32, key: [^]u8, kl: i32, value: [^]u8, vl: i32) -> i32 {
	context = ctx()
	k, ok := storage_kind(kind)
	if !ok { return i32(dom.Error.Invalid_Argument) }
	return storage_set_item(page_of(env), k, utf8_scrub(str(key, kl), context.temp_allocator), utf8_scrub(str(value, vl), context.temp_allocator))
}

n_Storage_removeItem :: proc "c" (env: wasm.Exec_Env, kind: i32, key: [^]u8, kl: i32) -> i32 {
	context = ctx()
	k, ok := storage_kind(kind)
	if !ok { return i32(dom.Error.Invalid_Argument) }
	return storage_remove_item(page_of(env), k, str(key, kl))
}

n_Storage_clear :: proc "c" (env: wasm.Exec_Env, kind: i32) -> i32 {
	context = ctx()
	k, ok := storage_kind(kind)
	if !ok { return i32(dom.Error.Invalid_Argument) }
	return storage_clear(page_of(env), k)
}

// StorageEvent fields: 0 key, 1 oldValue, 2 newValue, 3 url. Not_Found when the field is null.
n_StorageEvent_get :: proc "c" (env: wasm.Exec_Env, ev: u64, field: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	d := event_detail(page_of(env), ev)
	if d == nil || d.type != "storage" { return i32(dom.Error.Invalid_Handle) }
	switch field {
	case 0: if d.flags & 1 != 0 { return i32(dom.Error.Not_Found) }; return out_string(d.key, buf, cap)
	case 1: if d.flags & 2 != 0 { return i32(dom.Error.Not_Found) }; return out_string(d.old_value, buf, cap)
	case 2: if d.flags & 4 != 0 { return i32(dom.Error.Not_Found) }; return out_string(d.new_value, buf, cap)
	case 3: return out_string(d.url, buf, cap)
	}
	return i32(dom.Error.Invalid_Argument)
}

// StorageEvent.storageArea: 0 localStorage, 1 sessionStorage.
n_StorageEvent_storageArea :: proc "c" (env: wasm.Exec_Env, ev: u64) -> i32 {
	context = ctx()
	d := event_detail(page_of(env), ev)
	if d == nil || d.type != "storage" { return i32(dom.Error.Invalid_Handle) }
	return i32(d.area)
}

storage_symbols := [?]wasm.Native_Symbol{
	{"Storage_length", rawptr(n_Storage_length), "(i)i", nil},
	{"Storage_key", rawptr(n_Storage_key), "(ii*~)i", nil},
	{"Storage_getItem", rawptr(n_Storage_getItem), "(i*~*~)i", nil},
	{"Storage_setItem", rawptr(n_Storage_setItem), "(i*~*~)i", nil},
	{"Storage_removeItem", rawptr(n_Storage_removeItem), "(i*~)i", nil},
	{"Storage_clear", rawptr(n_Storage_clear), "(i)i", nil},
	{"StorageEvent_get", rawptr(n_StorageEvent_get), "(Ii*~)i", nil},
	{"StorageEvent_storageArea", rawptr(n_StorageEvent_storageArea), "(I)i", nil},
}
