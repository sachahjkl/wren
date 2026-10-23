package page

// What the profile's storage keeps for each site, and how it is removed (about:sites, "Clear site data"): localStorage (a file
// per origin in <profile>/storage), sessionStorage (in memory, per tab and origin), IndexedDB (a journal per origin in
// <profile>/idb). A storage key is an origin, followed by "^" and the top-level site for a frame of another site (see
// storage_origin_key): the pages of one site may hold several keys (ports, schemes, partitions). Cookies and the HTTP cache
// are the shell's (they are not in this package).

import "core:os"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:idb"

Site_Kind :: enum u8 { Local, Session, Indexed_Db }
Site_Kinds :: bit_set[Site_Kind]

// One storage key's data. A size is bytes on the disk when the data is there, else what is held in memory.
Site_Data :: struct {
	key:          string,   // temporary
	local_bytes:  i64,
	local_keys:   int,      // -1: not read yet (only its file's size is known)
	session_bytes: i64,
	session_keys: int,
	idb_bytes:    i64,
	idb_dbs:      int,      // -1: not loaded (only its file's size is known)
}

// The key a file name stands for (the inverse of the escaping of area_path and idb.origin_key_path: _XX for each byte outside
// [a-z0-9.-]); ok false for a name that is not one of ours.
@(private)
key_of_file :: proc(name, ext: string) -> (key: string, ok: bool) {
	if !strings.has_suffix(name, ext) { return "", false }
	stem := name[:len(name) - len(ext)]
	b := make([dynamic]byte, 0, len(stem), context.temp_allocator)
	hex :: proc(c: u8) -> int {
		switch {
		case c >= '0' && c <= '9': return int(c - '0')
		case c >= 'A' && c <= 'F': return int(c - 'A') + 10
		case c >= 'a' && c <= 'f': return int(c - 'a') + 10
		}
		return -1
	}
	for i := 0; i < len(stem); i += 1 {
		if stem[i] == '_' {
			if i + 2 >= len(stem) { return "", false }
			h, l := hex(stem[i + 1]), hex(stem[i + 2])
			if h < 0 || l < 0 { return "", false }
			append(&b, u8(h << 4 | l))
			i += 2
		} else {
			append(&b, stem[i])
		}
	}
	return string(b[:]), true
}

// The sites with data, by key (sorted). Temporary memory unless `allocator` says otherwise.
storage_sites :: proc(m: ^Storage_Manager, allocator := context.temp_allocator) -> []Site_Data {
	out := make(map[string]^Site_Data, allocator = context.temp_allocator)
	get :: proc(out: ^map[string]^Site_Data, key: string) -> ^Site_Data {
		if s, ok := out[key]; ok { return s }
		s := new(Site_Data, context.temp_allocator)
		s.key = strings.clone(key, context.temp_allocator)
		s.local_keys, s.idb_dbs = -1, -1
		out[s.key] = s
		return s
	}
	if m == nil || !m.ready { return nil }
	if m.dir != "" {
		if files, err := os.read_all_directory_by_path(storage_dir(m), context.temp_allocator); err == nil {
			for f in files {
				if k, ok := key_of_file(f.name, ".wls"); ok { s := get(&out, k); s.local_bytes = f.size }
			}
		}
		if files, err := os.read_all_directory_by_path(strings.concatenate({m.dir, "/idb"}, context.temp_allocator), context.temp_allocator); err == nil {
			for f in files {
				if k, ok := key_of_file(f.name, ".widb"); ok { s := get(&out, k); s.idb_bytes = f.size }
			}
		}
	}
	for _, a in m.areas {
		if a.state != .Loaded { continue }
		s := get(&out, a.origin)
		switch a.kind {
		case .Local:
			s.local_keys = len(a.items)
			s.local_bytes = max(s.local_bytes, i64(a.used) * 2)
		case .Session:
			s.session_keys += len(a.items)
			s.session_bytes += i64(a.used) * 2
		}
	}
	if m.idb != nil {
		for k, s in out {
			if bytes, dbs, loaded := idb.manager_usage(&m.idb.m, k); loaded {
				s.idb_dbs = dbs
				s.idb_bytes = max(s.idb_bytes, bytes)
			}
		}
		for k in idb.manager_loaded_keys(&m.idb.m, context.temp_allocator) {
			if _, ok := out[k]; !ok { _ = get(&out, k) }
			s := out[k]
			bytes, dbs, _ := idb.manager_usage(&m.idb.m, k)
			s.idb_dbs, s.idb_bytes = dbs, max(s.idb_bytes, bytes)
		}
	}
	list := make([dynamic]Site_Data, 0, len(out), allocator)
	for _, s in out {
		// (an area that was cleared leaves an empty file: nothing to list)
		if s.local_bytes <= 8 && s.local_keys <= 0 { s.local_bytes = 0 }
		if s.local_bytes == 0 && s.session_bytes == 0 && s.session_keys == 0 && s.idb_bytes <= 8 && s.idb_dbs <= 0 { continue }
		append(&list, s^)
	}
	slice.sort_by(list[:], proc(a, b: Site_Data) -> bool { return a.key < b.key })
	return list[:]
}

// Removes what the kinds name for one storage key. Open pages see empty areas; IndexedDB connections get "close".
storage_clear_site :: proc(m: ^Storage_Manager, key: string, kinds: Site_Kinds) {
	if m == nil || !m.ready { return }
	if .Local in kinds {
		if a, ok := m.areas[key]; ok && a.kind == .Local {
			area_clear(a)
			a.dirty = false
			area_write(m, a, false)   // an empty snapshot: ordered with the writes in flight, never overtaken by an older one
		} else if m.dir != "" {
			_ = os.remove(area_path(m, key))
		}
	}
	if .Session in kinds {
		for _, a in m.areas { if a.kind == .Session && a.origin == key { area_clear(a) } }
	}
	if .Indexed_Db in kinds { idb_clear_origin(m, key) }
}

// The host of a storage key (an origin, possibly followed by "^top-level site"): "https://a.example:8443^https://b.example" -> a.example.
storage_key_host :: proc(key: string) -> string {
	k := key
	if i := strings.index_byte(k, '^'); i >= 0 { k = k[:i] }
	if i := strings.index(k, "://"); i >= 0 { k = k[i + 3:] }
	if strings.has_prefix(k, "[") {
		if j := strings.index_byte(k, ']'); j >= 0 { return k[:j + 1] }
	}
	if i := strings.index_byte(k, ':'); i >= 0 { k = k[:i] }
	return k
}

_ :: base
