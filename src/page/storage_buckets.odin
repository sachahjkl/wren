package page

// Storage buckets and the storage manager of a page (navigator.storageBuckets, navigator.storage): the buckets an origin has
// opened (a name, whether it asked to be persistent, a durability hint, an expiry), each with its own IndexedDB (the storage key
// of the manager is the origin's followed by the bucket's name: its databases, quota and files are its own), and the persistence
// flag of the origin's default bucket. Both are kept in small files of the profile (`buckets.txt`, `persisted.txt`) read when
// first needed. `estimate` is real: what the origin's data takes (localStorage, sessionStorage, IndexedDB: storage_sites)
// against what the origin may keep (the preferences' quotas).

import "core:os"
import "core:strings"
import "core:sync"

Bucket_Info :: struct {
	origin:     string,
	name:       string,
	persisted:  bool,
	durability: string,   // "strict" | "relaxed"
	expires:    f64,      // ms since the epoch, -1: none
}

@(private)
Buckets_State :: struct {
	loaded:    bool,
	list:      [dynamic]Bucket_Info,
	persisted: map[string]bool,   // the keys whose default bucket asked for persistence
}

@(private)
buckets_state: Buckets_State
@(private)
buckets_mu: sync.Mutex   // pages and workers (threads of their own) ask

@(private)
buckets_path :: proc(m: ^Storage_Manager) -> string { return strings.concatenate({m.dir, "/buckets.txt"}, context.temp_allocator) }

@(private)
persisted_path :: proc(m: ^Storage_Manager) -> string { return strings.concatenate({m.dir, "/persisted.txt"}, context.temp_allocator) }

@(private)
buckets_load :: proc(m: ^Storage_Manager) {
	s := &buckets_state
	if s.loaded { return }
	s.loaded = true
	s.persisted = make(map[string]bool)
	if m.dir == "" { return }
	if data, err := os.read_entire_file(buckets_path(m), context.temp_allocator); err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) < 5 { continue }
			exp := 0.0
			for ch in f[4] { if ch >= '0' && ch <= '9' { exp = exp * 10 + f64(ch - '0') } }
			if f[4] == "-1" { exp = -1 }
			append(&s.list, Bucket_Info{origin = strings.clone(f[0]), name = strings.clone(f[1]), persisted = f[2] == "1", durability = strings.clone(f[3]), expires = exp})
		}
	}
	if data, err := os.read_entire_file(persisted_path(m), context.temp_allocator); err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) { if line != "" { s.persisted[strings.clone(line)] = true } }
	}
}

@(private)
buckets_save :: proc(m: ^Storage_Manager) {
	if m.dir == "" { return }
	s := &buckets_state
	b := strings.builder_make(context.temp_allocator)
	for x in s.list { strings.write_string(&b, x.origin); strings.write_byte(&b, '\t'); strings.write_string(&b, x.name); strings.write_byte(&b, '\t')
		strings.write_string(&b, "1" if x.persisted else "0"); strings.write_byte(&b, '\t'); strings.write_string(&b, x.durability); strings.write_byte(&b, '\t')
		strings.write_string(&b, int_text(i64(x.expires)) if x.expires >= 0 else "-1"); strings.write_byte(&b, '\n') }
	_ = os.write_entire_file(buckets_path(m), transmute([]byte)strings.to_string(b))
	p := strings.builder_make(context.temp_allocator)
	for k, v in s.persisted { if v { strings.write_string(&p, k); strings.write_byte(&p, '\n') } }
	_ = os.write_entire_file(persisted_path(m), transmute([]byte)strings.to_string(p))
}

@(private)
int_text :: proc(n: i64) -> string {
	buf: [24]byte
	i := len(buf)
	x := n
	if x == 0 { return "0" }
	for x > 0 { i -= 1; buf[i] = byte('0' + x % 10); x /= 10 }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

// The storage key of an origin's bucket (the manager's key for its IndexedDB).
bucket_key :: proc(origin_key, bucket: string) -> string {
	if bucket == "" { return origin_key }
	return strings.concatenate({origin_key, "\x00bucket=", bucket}, context.temp_allocator)
}

@(private)
bucket_find :: proc(origin, name: string) -> int {
	for x, i in buckets_state.list { if x.origin == origin && x.name == name { return i } }
	return -1
}

// Opens (makes if it is new) the bucket `name` of the origin. `created`: it did not exist.
bucket_open :: proc(m: ^Storage_Manager, origin, name: string, persisted: bool, durability: string, expires: f64) -> (info: Bucket_Info, created: bool) {
	sync.mutex_lock(&buckets_mu); defer sync.mutex_unlock(&buckets_mu)
	buckets_load(m)
	if i := bucket_find(origin, name); i >= 0 {
		x := &buckets_state.list[i]
		if persisted { x.persisted = true }
		if durability != "" { x.durability = strings.clone(durability) }
		if expires >= 0 { x.expires = expires }
		buckets_save(m)
		return x^, false
	}
	x := Bucket_Info{origin = strings.clone(origin), name = strings.clone(name), persisted = persisted, durability = strings.clone(durability if durability != "" else "relaxed"), expires = expires}
	append(&buckets_state.list, x)
	buckets_save(m)
	return x, true
}

bucket_names :: proc(m: ^Storage_Manager, origin: string) -> []string {
	sync.mutex_lock(&buckets_mu); defer sync.mutex_unlock(&buckets_mu)
	buckets_load(m)
	out := make([dynamic]string, context.temp_allocator)
	append(&out, "default")
	for x in buckets_state.list { if x.origin == origin { append(&out, x.name) } }
	return out[:]
}

// Removes a bucket and everything it keeps.
bucket_delete :: proc(m: ^Storage_Manager, origin, name: string) {
	sync.mutex_lock(&buckets_mu); defer sync.mutex_unlock(&buckets_mu)
	buckets_load(m)
	if i := bucket_find(origin, name); i >= 0 { ordered_remove(&buckets_state.list, i) }
	idb_clear_origin(m, bucket_key(origin, name))
	delete_key(&buckets_state.persisted, bucket_key(origin, name))
	buckets_save(m)
}

bucket_set_expires :: proc(m: ^Storage_Manager, origin, name: string, expires: f64) {
	sync.mutex_lock(&buckets_mu); defer sync.mutex_unlock(&buckets_mu)
	buckets_load(m)
	if i := bucket_find(origin, name); i >= 0 { buckets_state.list[i].expires = expires; buckets_save(m) }
}

// persisted() and persist() of the default bucket (key: the origin's storage key) or of a named bucket.
storage_persisted :: proc(m: ^Storage_Manager, key: string, bucket: string, request: bool) -> bool {
	sync.mutex_lock(&buckets_mu); defer sync.mutex_unlock(&buckets_mu)
	buckets_load(m)
	if bucket != "" {
		if i := bucket_find(key, bucket); i >= 0 {
			if request && !buckets_state.list[i].persisted { buckets_state.list[i].persisted = true; buckets_save(m) }
			return buckets_state.list[i].persisted
		}
		return false
	}
	if request && !buckets_state.persisted[key] { buckets_state.persisted[strings.clone(key)] = true; buckets_save(m) }
	return buckets_state.persisted[key]
}

// What the origin's bucket holds, and what it may hold.
storage_estimate :: proc(m: ^Storage_Manager, key: string, bucket: string, idb_quota: i64, local_quota_units: int) -> (usage, quota: i64) {
	for s in storage_sites(m) {
		if s.key == bucket_key(key, bucket) {
			usage = s.idb_bytes
			if bucket == "" { usage += s.local_bytes + s.session_bytes }
		}
	}
	quota = idb_quota
	if bucket == "" { quota += i64(local_quota_units) * 2 }
	return
}
