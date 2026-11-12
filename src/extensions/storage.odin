package extensions

// The storage areas of an extension (chrome.storage): local, sync and session. An area maps keys to JSON texts, counts
// its bytes as Chrome does (key length + JSON length) and refuses a write past its limits; nothing is dropped silently.
// local and sync are written to the profile by their owner (the text of area_serialize); session lives in memory only.

import "core:encoding/json"
import "core:slice"
import "core:strings"

Area_Kind :: enum u8 { Local, Sync, Session, Managed }
AREA_NAMES := [Area_Kind]string{.Local = "local", .Sync = "sync", .Session = "session", .Managed = "managed"}

Area :: struct {
	items:     map[string]string,   // key -> JSON text (both owned)
	bytes:     int,
	max_bytes: int,                 // 0: no limit (unlimitedStorage)
	max_items: int,                 // 0: no limit
	max_item:  int,                 // 0: no limit
	dirty:     bool,                // changed since its owner saved it
}

Area_Error :: enum u8 { None, Quota_Bytes, Quota_Items, Quota_Item }

area_error_text :: proc(e: Area_Error) -> string {
	switch e {
	case .None:        return ""
	case .Quota_Bytes: return "QUOTA_BYTES quota exceeded"
	case .Quota_Items: return "MAX_ITEMS quota exceeded"
	case .Quota_Item:  return "QUOTA_BYTES_PER_ITEM quota exceeded"
	}
	return ""
}

area_destroy :: proc(a: ^Area) {
	for k, v in a.items { delete(k); delete(v) }
	delete(a.items)
	a.items = nil
	a.bytes = 0
}

@(private = "file")
item_size :: proc(k, v: string) -> int { return len(k) + len(v) }

// One change of a write: the old value ("" with had false when there was none) and the new one (removed: "").
Area_Change :: struct {
	key:      string,
	old, new: string,
	had, has: bool,
}

// Sets every pair of `pairs` (key -> JSON text) at once, or none: the limits are checked against the result. The changes
// (temp allocator) are what storage.onChanged reports; a value set to the same text is no change.
area_set :: proc(a: ^Area, keys: []string, values: []string) -> ([]Area_Change, Area_Error) {
	after := a.bytes
	count := len(a.items)
	for k, i in keys {
		v := values[i]
		if a.max_item > 0 && item_size(k, v) > a.max_item { return nil, .Quota_Item }
		if old, had := a.items[k]; had { after -= item_size(k, old) } else { count += 1 }
		after += item_size(k, v)
	}
	if a.max_bytes > 0 && after > a.max_bytes { return nil, .Quota_Bytes }
	if a.max_items > 0 && count > a.max_items { return nil, .Quota_Items }
	changes := make([dynamic]Area_Change, 0, len(keys), context.temp_allocator)
	for k, i in keys {
		v := values[i]
		if old, had := a.items[k]; had {
			if old == v { continue }
			append(&changes, Area_Change{key = strings.clone(k, context.temp_allocator), old = strings.clone(old, context.temp_allocator), new = strings.clone(v, context.temp_allocator), had = true, has = true})
			a.bytes -= item_size(k, old)
			delete(old)
			a.items[k] = strings.clone(v)
		} else {
			append(&changes, Area_Change{key = strings.clone(k, context.temp_allocator), new = strings.clone(v, context.temp_allocator), has = true})
			a.items[strings.clone(k)] = strings.clone(v)
		}
		a.bytes += item_size(k, v)
	}
	if len(changes) > 0 { a.dirty = true }
	return changes[:], .None
}

area_remove :: proc(a: ^Area, keys: []string) -> []Area_Change {
	changes := make([dynamic]Area_Change, 0, len(keys), context.temp_allocator)
	for k in keys {
		if k not_in a.items { continue }
		key, old := delete_key(&a.items, k)
		append(&changes, Area_Change{key = strings.clone(key, context.temp_allocator), old = strings.clone(old, context.temp_allocator), had = true})
		a.bytes -= item_size(key, old)
		delete(key)
		delete(old)
	}
	if len(changes) > 0 { a.dirty = true }
	return changes[:]
}

area_clear :: proc(a: ^Area) -> []Area_Change {
	keys := make([dynamic]string, 0, len(a.items), context.temp_allocator)
	for k in a.items { append(&keys, strings.clone(k, context.temp_allocator)) }
	return area_remove(a, keys[:])
}

// The bytes of `keys` (nil: all of them), as getBytesInUse counts.
area_bytes_of :: proc(a: ^Area, keys: []string) -> int {
	if keys == nil { return a.bytes }
	n := 0
	for k in keys { if v, ok := a.items[k]; ok { n += item_size(k, v) } }
	return n
}

// The whole area as the profile keeps it (temp allocator unless told), keys sorted: one line per item, the key as a JSON
// string, a TAB, the value's JSON text. Values come from JSON.stringify without indentation: they hold no line break.
area_serialize :: proc(a: ^Area, allocator := context.temp_allocator) -> string {
	keys := make([dynamic]string, 0, len(a.items), context.temp_allocator)
	for k in a.items { append(&keys, k) }
	slice.sort(keys[:])
	b := strings.builder_make(allocator)
	for k in keys {
		strings.write_string(&b, json_quote(k))
		strings.write_byte(&b, '\t')
		strings.write_string(&b, a.items[k])
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Fills the area from what area_serialize wrote. A line that is not "key TAB value" is skipped (a torn write loses that
// item only); the value is kept as written, never parsed again.
area_load :: proc(a: ^Area, text: string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		tab := strings.index_byte(line, '\t')
		if tab <= 0 || tab == len(line) - 1 { continue }
		kv, err := json.parse_string(line[:tab], .JSON, false, context.temp_allocator)
		if err != .None { continue }
		k, ok := kv.(json.String)
		if !ok { continue }
		v := line[tab + 1:]
		if old, had := a.items[k]; had {
			a.bytes -= item_size(k, old)
			delete(old)
			a.items[k] = strings.clone(v)
		} else {
			a.items[strings.clone(k)] = strings.clone(v)
		}
		a.bytes += item_size(k, v)
	}
}
