package web

// localStorage / sessionStorage (import module "storage"). Missing keys are Error.Not_Found; Web_Error.Security for
// documents that may not use storage, Web_Error.Quota past the origin's quota.

foreign import storage_mod "storage"

Storage_Kind :: enum i32 { Local = 0, Session = 1 }

Storage_Event_Field :: enum i32 { Key = 0, Old_Value = 1, New_Value = 2, Url = 3 }

@(default_calling_convention = "contextless")
foreign storage_mod {
	Storage_length :: proc(kind: Storage_Kind) -> i32 ---
	@(link_name = "Storage_key") raw_storageKey :: proc(kind: Storage_Kind, index: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Storage_getItem") raw_storageGet :: proc(kind: Storage_Kind, key: [^]u8, kl: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Storage_setItem") raw_storageSet :: proc(kind: Storage_Kind, key: [^]u8, kl: i32, value: [^]u8, vl: i32) -> i32 ---
	@(link_name = "Storage_removeItem") raw_storageRemove :: proc(kind: Storage_Kind, key: [^]u8, kl: i32) -> i32 ---
	Storage_clear :: proc(kind: Storage_Kind) -> i32 ---
	@(link_name = "StorageEvent_get") raw_storageEventGet :: proc(ev: Handle, field: Storage_Event_Field, buf: [^]u8, cap: i32) -> i32 ---
	StorageEvent_storageArea :: proc(ev: Handle) -> Storage_Kind ---
}

// getItem: found = false for null; err < 0 for a SecurityError.
storage_get :: proc "contextless" (kind: Storage_Kind, key: string, buf: []u8) -> (value: string, found: bool, err: i32) {
	n := raw_storageGet(kind, raw_data(key), i32(len(key)), raw_data(buf), i32(len(buf)))
	if n == i32(Error.Not_Found) { return "", false, 0 }
	if n < 0 { return "", false, n }
	return string(buf[:min(int(n), len(buf))]), true, 0
}

storage_set :: proc "contextless" (kind: Storage_Kind, key, value: string) -> i32 {
	return raw_storageSet(kind, raw_data(key), i32(len(key)), raw_data(value), i32(len(value)))
}

storage_remove :: proc "contextless" (kind: Storage_Kind, key: string) -> i32 {
	return raw_storageRemove(kind, raw_data(key), i32(len(key)))
}

storage_key :: proc "contextless" (kind: Storage_Kind, index: int, buf: []u8) -> (key: string, found: bool) {
	n := raw_storageKey(kind, i32(index), raw_data(buf), i32(len(buf)))
	if n < 0 { return "", false }
	return string(buf[:min(int(n), len(buf))]), true
}

// A field of a StorageEvent; found = false when it is null.
storage_event_field :: proc "contextless" (ev: Handle, field: Storage_Event_Field, buf: []u8) -> (s: string, found: bool) {
	n := raw_storageEventGet(ev, field, raw_data(buf), i32(len(buf)))
	if n < 0 { return "", false }
	return string(buf[:min(int(n), len(buf))]), true
}
