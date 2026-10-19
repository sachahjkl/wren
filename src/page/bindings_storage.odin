package page

// localStorage / sessionStorage (Web Storage; import module "storage"). Null results are Not_Found; an opaque origin or
// disabled storage is Security; a write past the quota is Quota. The store itself is storage.odin, whose errors are
// the API's codes (WEB_ERR_*).

@(private)
storage_kind :: #force_inline proc "contextless" (a: Api_StorageArea) -> Storage_Kind { return a == .Session ? .Session : .Local }

Storage_length :: proc(c: ^Call, area: Api_StorageArea) -> (i32, Api_Error) {
	n, err := storage_length(c.page, storage_kind(area))
	if err != 0 { return 0, Api_Error(err) }
	return i32(n), .None
}

Storage_key :: proc(c: ^Call, area: Api_StorageArea, index: i32) -> (string, Api_Error) {
	key, found, err := storage_key(c.page, storage_kind(area), int(index))
	if err != 0 { return "", Api_Error(err) }
	if !found { return "", .Not_Found }
	return key, .None
}

Storage_getItem :: proc(c: ^Call, area: Api_StorageArea, key: string) -> (string, Api_Error) {
	v, found, err := storage_get_item(c.page, storage_kind(area), key)
	if err != 0 { return "", Api_Error(err) }
	if !found { return "", .Not_Found }
	return v, .None
}

Storage_setItem :: proc(c: ^Call, area: Api_StorageArea, key, value: string) -> Api_Error {
	return Api_Error(storage_set_item(c.page, storage_kind(area), key, value))
}

Storage_removeItem :: proc(c: ^Call, area: Api_StorageArea, key: string) -> Api_Error {
	return Api_Error(storage_remove_item(c.page, storage_kind(area), key))
}

Storage_clear :: proc(c: ^Call, area: Api_StorageArea) -> Api_Error {
	return Api_Error(storage_clear(c.page, storage_kind(area)))
}

// StorageEvent fields: Not_Found when the field is null.
StorageEvent_get :: proc(c: ^Call, event: Api_Event, field: Api_StorageEventField) -> (string, Api_Error) {
	d := event_detail(c.page, event.handle)
	if d == nil || d.type != "storage" { return "", fail(c, .Invalid_Handle, "not a storage event") }
	switch field {
	case .Key: if d.flags & 1 != 0 { return "", .Not_Found }; return d.key, .None
	case .Old_Value: if d.flags & 2 != 0 { return "", .Not_Found }; return d.old_value, .None
	case .New_Value: if d.flags & 4 != 0 { return "", .Not_Found }; return d.new_value, .None
	case .Url: return d.url, .None
	}
	return "", .Invalid_Argument
}

StorageEvent_storageArea :: proc(c: ^Call, event: Api_Event) -> (Api_StorageArea, Api_Error) {
	d := event_detail(c.page, event.handle)
	if d == nil || d.type != "storage" { return .Local, fail(c, .Invalid_Handle, "not a storage event") }
	return Api_StorageArea(d.area), .None
}