package page

// The Cache API's storage (Service Workers §5: CacheStorage, Cache), native and shared by every realm of the process
// (documents on the interface thread, workers and service workers on theirs): one mutex, never held while a realm
// runs. Per origin, named caches of request -> response entries; on disk under <profile>/caches/<origin>/: an index
// (index.wcs: every cache, every entry's request and response head) rewritten whole on change, and one file per body
// (<id>.body) written once. A profile without a directory keeps everything in memory.
//
// Matching (Cache "query cache"): the URLs without their fragments are equal (without their queries with
// ignoreSearch), the method is GET unless ignoreMethod. Vary is not consulted (as with ignoreVary).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

Cached_Response :: struct {
	id:           u64,
	url:          string,   // the request's URL, without its fragment
	method:       string,
	status:       int,
	status_text:  string,
	response_url: string,
	headers:      string,   // "Name: value\r\n" lines
	size:         i64,
	body:         []byte,   // in memory when the profile has no directory (else read from <id>.body)
}

Named_Cache :: struct {
	name:    string,
	entries: [dynamic]Cached_Response,
}

Origin_Caches :: struct {
	origin: string,
	dir:    string,           // "" = memory only
	caches: [dynamic]^Named_Cache,
	next:   u64,
	bytes:  i64,
}

Cache_Query :: struct {
	ignore_search: bool,
	ignore_method: bool,
}

@(private)
Cache_Store :: struct {
	mu:      sync.Mutex,
	origins: map[string]^Origin_Caches,   // key: profile dir + "\x00" + origin
}

@(private) cache_store: Cache_Store

@(private)
cached_free :: proc(e: ^Cached_Response) {
	delete(e.url); delete(e.method); delete(e.status_text); delete(e.response_url); delete(e.headers); delete(e.body)
}

@(private)
named_free :: proc(c: ^Named_Cache) {
	for &e in c.entries { cached_free(&e) }
	delete(c.entries)
	delete(c.name)
	free(c)
}

// Process end.
cache_store_shutdown :: proc() {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	for k, oc in cache_store.origins {
		for c in oc.caches { named_free(c) }
		delete(oc.caches); delete(oc.origin); delete(oc.dir); free(oc)
		delete(k)
	}
	delete(cache_store.origins)
	cache_store.origins = nil
}

// <profile>/caches/<origin with every byte outside [a-z0-9.-] as _XX>
@(private)
cache_origin_dir :: proc(profile_dir, origin: string) -> string {
	if profile_dir == "" { return "" }
	b := strings.builder_make()
	strings.write_string(&b, profile_dir)
	strings.write_string(&b, "/caches/")
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(origin) {
		c := origin[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' { strings.write_byte(&b, c) } else { strings.write_byte(&b, '_'); strings.write_byte(&b, HEX[c >> 4]); strings.write_byte(&b, HEX[c & 15]) }
	}
	return strings.to_string(b)
}

CACHE_MAGIC :: "WCS1"

@(private)
wcs_put_str :: proc(b: ^[dynamic]byte, s: string) {
	n := u32(len(s))
	append(b, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
	append(b, ..transmute([]byte)s)
}

@(private)
wcs_put_u64 :: proc(b: ^[dynamic]byte, v: u64) { for i in 0 ..< 8 { append(b, u8(v >> (8 * uint(i)))) } }

@(private)
Wcs_Reader :: struct { data: []byte, at: int, bad: bool }

@(private)
wcs_get_u64 :: proc(r: ^Wcs_Reader) -> u64 {
	if len(r.data) - r.at < 8 { r.bad = true; return 0 }
	v: u64
	for i in 0 ..< 8 { v |= u64(r.data[r.at + i]) << (8 * uint(i)) }
	r.at += 8
	return v
}

@(private)
wcs_get_str :: proc(r: ^Wcs_Reader) -> string {
	if len(r.data) - r.at < 4 { r.bad = true; return "" }
	n := int(u32(r.data[r.at]) | u32(r.data[r.at + 1]) << 8 | u32(r.data[r.at + 2]) << 16 | u32(r.data[r.at + 3]) << 24)
	r.at += 4
	if n > len(r.data) - r.at { r.bad = true; return "" }
	s := strings.clone(string(r.data[r.at:r.at + n]))
	r.at += n
	return s
}

// The index of an origin's caches as bytes (pure: tests).
cache_index_serialize :: proc(oc: ^Origin_Caches, allocator := context.allocator) -> []byte {
	b := make([dynamic]byte, allocator)
	append(&b, ..transmute([]byte)string(CACHE_MAGIC))
	wcs_put_u64(&b, oc.next)
	wcs_put_u64(&b, u64(len(oc.caches)))
	for c in oc.caches {
		wcs_put_str(&b, c.name)
		wcs_put_u64(&b, u64(len(c.entries)))
		for e in c.entries {
			wcs_put_u64(&b, e.id)
			wcs_put_str(&b, e.url); wcs_put_str(&b, e.method); wcs_put_u64(&b, u64(e.status)); wcs_put_str(&b, e.status_text)
			wcs_put_str(&b, e.response_url); wcs_put_str(&b, e.headers); wcs_put_u64(&b, u64(e.size))
		}
	}
	return b[:]
}

// Reads an index into `oc` (empty); false (and nothing kept) when it is not one.
cache_index_parse :: proc(oc: ^Origin_Caches, data: []byte) -> bool {
	if len(data) < 4 || string(data[:4]) != CACHE_MAGIC { return false }
	r := Wcs_Reader{data = data, at = 4}
	oc.next = wcs_get_u64(&r)
	n := wcs_get_u64(&r)
	for i: u64 = 0; i < n && !r.bad; i += 1 {
		c := new(Named_Cache)
		c.name = wcs_get_str(&r)
		ne := wcs_get_u64(&r)
		for j: u64 = 0; j < ne && !r.bad; j += 1 {
			e := Cached_Response{id = wcs_get_u64(&r)}
			e.url = wcs_get_str(&r); e.method = wcs_get_str(&r); e.status = int(wcs_get_u64(&r)); e.status_text = wcs_get_str(&r)
			e.response_url = wcs_get_str(&r); e.headers = wcs_get_str(&r); e.size = i64(wcs_get_u64(&r))
			append(&c.entries, e)
			oc.bytes += e.size
		}
		append(&oc.caches, c)
	}
	if r.bad {
		for c in oc.caches { named_free(c) }
		clear(&oc.caches)
		oc.bytes, oc.next = 0, 0
		return false
	}
	return true
}

// (locked) the caches of `origin` in the profile `dir`, loaded on first use.
@(private)
origin_caches :: proc(dir, origin: string) -> ^Origin_Caches {
	key := strings.concatenate({dir, "\x00", origin}, context.temp_allocator)
	if oc, ok := cache_store.origins[key]; ok { return oc }
	oc := new(Origin_Caches)
	oc.origin = strings.clone(origin)
	oc.dir = cache_origin_dir(dir, origin)
	if oc.dir != "" {
		if data, err := os.read_entire_file(strings.concatenate({oc.dir, "/index.wcs"}, context.temp_allocator), context.temp_allocator); err == nil {
			cache_index_parse(oc, data)
		}
	}
	cache_store.origins[strings.clone(key)] = oc
	return oc
}

// (locked)
@(private)
index_save :: proc(oc: ^Origin_Caches) {
	if oc.dir == "" { return }
	_ = os.make_directory_all(oc.dir)
	data := cache_index_serialize(oc, context.temp_allocator)
	path := strings.concatenate({oc.dir, "/index.wcs"}, context.temp_allocator)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil { return }
	if os.rename(tmp, path) != nil { _ = os.remove(path); _ = os.rename(tmp, path) }
}

@(private)
body_path :: proc(oc: ^Origin_Caches, id: u64) -> string { return fmt.tprintf("%s/%d.body", oc.dir, id) }

@(private)
find_cache :: proc(oc: ^Origin_Caches, name: string) -> (^Named_Cache, int) {
	for c, i in oc.caches { if c.name == name { return c, i } }
	return nil, -1
}

// URL without its fragment (and its query with ignore_search): what matching compares.
@(private)
cache_url_key :: proc(u: string, ignore_search: bool) -> string {
	s := u
	if i := strings.index_byte(s, '#'); i >= 0 { s = s[:i] }
	if ignore_search { if i := strings.index_byte(s, '?'); i >= 0 { s = s[:i] } }
	return s
}

cache_entry_matches :: proc(e: ^Cached_Response, url, method: string, q: Cache_Query) -> bool {
	if !q.ignore_method && method != "GET" && method != "" { return false }
	return cache_url_key(e.url, q.ignore_search) == cache_url_key(url, q.ignore_search)
}

////////////////////////////////
// Operations (thread-safe)

cache_open :: proc(dir, origin, name: string) {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	oc := origin_caches(dir, origin)
	if c, _ := find_cache(oc, name); c != nil { return }
	c := new(Named_Cache)
	c.name = strings.clone(name)
	append(&oc.caches, c)
	index_save(oc)
}

cache_has :: proc(dir, origin, name: string) -> bool {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	c, _ := find_cache(origin_caches(dir, origin), name)
	return c != nil
}

cache_delete_named :: proc(dir, origin, name: string) -> bool {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	oc := origin_caches(dir, origin)
	c, i := find_cache(oc, name)
	if c == nil { return false }
	for e in c.entries {
		oc.bytes -= e.size
		if oc.dir != "" { _ = os.remove(body_path(oc, e.id)) }
	}
	ordered_remove(&oc.caches, i)
	named_free(c)
	index_save(oc)
	return true
}

// The names, in creation order, "\n"-separated (temporary allocator).
cache_names :: proc(dir, origin: string) -> string {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	oc := origin_caches(dir, origin)
	b := strings.builder_make(context.temp_allocator)
	for c, i in oc.caches { if i > 0 { strings.write_byte(&b, '\n') }; strings.write_string(&b, c.name) }
	return strings.to_string(b)
}

// The ids of the entries of cache `name` matching (all of them with url = ""), in insertion order (temporary).
cache_match_ids :: proc(dir, origin, name, url, method: string, q: Cache_Query) -> []u64 {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	out := make([dynamic]u64, context.temp_allocator)
	c, _ := find_cache(origin_caches(dir, origin), name)
	if c == nil { return nil }
	for &e in c.entries { if url == "" || cache_entry_matches(&e, url, method, q) { append(&out, e.id) } }
	return out[:]
}

// An entry's request and response head (copies in the temporary allocator); ok = false when it is gone.
cache_entry_head :: proc(dir, origin, name: string, id: u64) -> (e: Cached_Response, ok: bool) {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	c, _ := find_cache(origin_caches(dir, origin), name)
	if c == nil { return }
	for x in c.entries {
		if x.id != id { continue }
		t := context.temp_allocator
		return Cached_Response{id = x.id, url = strings.clone(x.url, t), method = strings.clone(x.method, t), status = x.status,
			status_text = strings.clone(x.status_text, t), response_url = strings.clone(x.response_url, t), headers = strings.clone(x.headers, t), size = x.size}, true
	}
	return
}

// An entry's body (allocated with `allocator`); ok = false when it is gone or unreadable.
cache_entry_body :: proc(dir, origin, name: string, id: u64, allocator := context.allocator) -> (body: []byte, ok: bool) {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	oc := origin_caches(dir, origin)
	c, _ := find_cache(oc, name)
	if c == nil { return }
	for x in c.entries {
		if x.id != id { continue }
		if oc.dir == "" {
			out := make([]byte, len(x.body), allocator)
			copy(out, x.body)
			return out, true
		}
		data, err := os.read_entire_file(body_path(oc, id), allocator)
		return data, err == nil
	}
	return
}

Cache_Put_Error :: enum u8 { None, No_Cache, Quota }

// Stores an entry (replacing those that match its request), creating cache `name` if it went away meanwhile.
cache_put :: proc(dir, origin, name: string, e: Cached_Response, body: []byte, max_bytes: i64) -> Cache_Put_Error {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	oc := origin_caches(dir, origin)
	c, _ := find_cache(oc, name)
	if c == nil {
		c = new(Named_Cache)
		c.name = strings.clone(name)
		append(&oc.caches, c)
	}
	freed: i64
	for &x in c.entries { if cache_entry_matches(&x, e.url, "GET", {}) { freed += x.size } }
	if oc.bytes - freed + i64(len(body)) > max_bytes { return .Quota }
	k := 0
	for &x in c.entries {
		if cache_entry_matches(&x, e.url, "GET", {}) {
			oc.bytes -= x.size
			if oc.dir != "" { _ = os.remove(body_path(oc, x.id)) }
			cached_free(&x)
			continue
		}
		c.entries[k] = x
		k += 1
	}
	resize(&c.entries, k)
	oc.next += 1
	ne := Cached_Response{
		id = oc.next, url = strings.clone(cache_url_key(e.url, false)), method = strings.clone("GET"), status = e.status,
		status_text = strings.clone(e.status_text), response_url = strings.clone(e.response_url), headers = strings.clone(e.headers), size = i64(len(body)),
	}
	if oc.dir == "" {
		ne.body = make([]byte, len(body))
		copy(ne.body, body)
	} else {
		_ = os.make_directory_all(oc.dir)
		if os.write_entire_file(body_path(oc, ne.id), body) != nil { cached_free(&ne); return .Quota }
	}
	append(&c.entries, ne)
	oc.bytes += ne.size
	index_save(oc)
	return .None
}

// Removes the entries matching; true when there were some.
cache_delete_entries :: proc(dir, origin, name, url, method: string, q: Cache_Query) -> bool {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	oc := origin_caches(dir, origin)
	c, _ := find_cache(oc, name)
	if c == nil { return false }
	k, removed := 0, false
	for &x in c.entries {
		if cache_entry_matches(&x, url, method, q) {
			oc.bytes -= x.size
			if oc.dir != "" { _ = os.remove(body_path(oc, x.id)) }
			cached_free(&x)
			removed = true
			continue
		}
		c.entries[k] = x
		k += 1
	}
	resize(&c.entries, k)
	if removed { index_save(oc) }
	return removed
}

// Bytes the Cache API keeps for an origin (StorageManager.estimate).
cache_usage :: proc(dir, origin: string) -> i64 {
	sync.mutex_lock(&cache_store.mu)
	defer sync.mutex_unlock(&cache_store.mu)
	return origin_caches(dir, origin).bytes
}
