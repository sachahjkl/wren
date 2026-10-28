// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=storage order=64 exposed=Window
/// localStorage and sessionStorage (Web Storage). Security for an opaque origin or disabled storage, Quota for a write
/// past the quota, Not_Found for a null result.
package api_storage

StorageArea :: enum i32 {
	Local,
	Session,
}

/// A field of a StorageEvent.
StorageEventField :: enum i32 {
	Key,
	Old_Value,
	New_Value,
	Url,
}

/// storage.length
//@wb fn raises
Storage_length :: proc(area: StorageArea) -> i32

/// storage.key(index)
//@wb fn raises
Storage_key :: proc(area: StorageArea, index: i32) -> string

/// storage.getItem(key)
//@wb fn raises
Storage_getItem :: proc(area: StorageArea, key: string) -> string

/// storage.setItem(key, value)
//@wb fn raises
Storage_setItem :: proc(area: StorageArea, key: usvstring, value: usvstring)

/// storage.removeItem(key)
//@wb fn raises
Storage_removeItem :: proc(area: StorageArea, key: string)

/// storage.clear()
//@wb fn raises
Storage_clear :: proc(area: StorageArea)

/// A field of a "storage" event: Not_Found when null, Invalid_Handle for another event.
//@wb fn raises
StorageEvent_get :: proc(event: Event, field: StorageEventField) -> string

/// StorageEvent.storageArea
//@wb fn raises
StorageEvent_storageArea :: proc(event: Event) -> StorageArea

