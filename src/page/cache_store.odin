package page

// The Cache API's storage (Service Workers §5: CacheStorage, Cache), native and shared by every realm of the process
// (documents on the interface thread, workers and service workers on theirs).
//
// Concurrency and I/O design:
//   * `cache_store.mu` guards only fast in-memory metadata lookups and mutations; it is NEVER held across any
//     filesystem call (no read, write, rename, or remove under the lock).
//   * Each Named_Cache indexes entries by entry id (`by_id`), by URL without fragment (`by_url`), and by URL without
//     query or fragment (`by_base_url`), avoiding O(N) scans on put, match, head/body reads, and delete.
//   * Disk writes (`<id>.body`), deletions, and debounced `index.wcs` snapshots run in FIFO mutation order on a lazy
//     background writer thread (`Cache_Writer`), so the UI thread never blocks on disk writes and rapid bursts (such
//     as `cache.addAll`) coalesce into a single atomic `index.wcs` write.
//   * Newly stored disk entries retain their body bytes in memory (`body_resident = true`) until the writer finishes
//     persisting `<id>.body`, guaranteeing read-after-write coherence without waiting on disk and releasing memory
//     immediately after persistence.
//   * `cache_store_flush` and `cache_store_shutdown` drain all queued writes/deletes and flush every dirty index
//     before returning, preserving durability with zero leaks.
//
// Matching (Cache "query cache"): the URLs without their fragments are equal (without their queries with
// ignoreSearch), the method is GET unless ignoreMethod, and unless ignoreVary every header the stored response's Vary
// names has the same value in the request as in the stored request (Vary: * matches nothing).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"

// Debounce window before coalesced `index.wcs` mutations are flushed to disk on the writer thread.
CACHE_INDEX_DEBOUNCE_MS :: 150

Cached_Response :: struct {
	id:            u64,
	url:           string,   // the request's URL, without its fragment
	method:        string,
	status:        int,
	status_text:   string,
	response_url:  string,
	headers:       string,   // "Name: value\r\n" lines
	req_headers:   string,   // the request's header lines (Vary)
	size:          i64,
	body:          []byte,   // held in memory for memory-only profiles, or while a disk write is in flight
	body_resident: bool,     // true when `body` holds the complete body in memory (including empty bodies)
}

Named_Cache :: struct {
	name:        string,
	entries:     [dynamic]Cached_Response,
	by_id:       map[u64]int,              // entry id -> index in `entries`
	by_url:      map[string][dynamic]u64,  // url without fragment -> entry ids in insertion order
	by_base_url: map[string][dynamic]u64,  // url without query or fragment -> entry ids in insertion order
}

Origin_Caches :: struct {
	origin:    string,
	dir:       string,                 // "" = memory only
	caches:    [dynamic]^Named_Cache,
	by_name:   map[string]^Named_Cache, // name -> cache (borrows c.name; populated on live store origins)
	next:      u64,
	bytes:     i64,
	dirty:     bool,                   // index.wcs has unflushed mutations
	dirty_gen: u64,
}

Cache_Query :: struct {
	ignore_search: bool,
	ignore_method: bool,
	ignore_vary:   bool,
}

@(private)
Cache_Store :: struct {
	mu:      sync.Mutex,
	origins: map[string]^Origin_Caches,   // key: profile dir + "\x00" + origin
	writer:  ^Cache_Writer,               // lazily started on first disk mutation
}

@(private = "file")
Cache_Disk_Op_Kind :: enum u8 {
	Write_Body,
	Delete_Body,
}

@(private = "file")
Cache_Disk_Op :: struct {
	kind:       Cache_Disk_Op_Kind,
	origin_key: string,   // process_allocator (Write_Body)
	cache_name: string,   // process_allocator (Write_Body)
	dir:        string,   // process_allocator (Write_Body)
	path:       string,   // process_allocator
	id:         u64,      // Write_Body
	body:       []byte,   // process_allocator (Write_Body)
}

@(private)
Cache_Writer :: struct {
	store:         ^Cache_Store,
	mu:            sync.Mutex,
	cond:          sync.Cond,
	idle:          sync.Cond,
	queue:         [dynamic]Cache_Disk_Op,
	head:          int,
	dirty_pending: bool,
	dirty_since:   time.Tick,
	flush_req:     u64,
	done_seq:      u64,
	stopping:      bool,
	thread:        ^host.Thread,
}

@(private = "file")
cache_alloc :: #force_inline proc() -> runtime.Allocator { return base.process_allocator() }

@(private)
cached_free :: proc(e: ^Cached_Response) {
	delete(e.url); delete(e.method); delete(e.status_text); delete(e.response_url); delete(e.headers); delete(e.req_headers); delete(e.body)
}

@(private = "file")
id_bucket_add :: proc(m: ^map[string][dynamic]u64, key: string, id: u64) {
	if list, ok := &m^[key]; ok {
		append(list, id)
		return
	}
	list := make([dynamic]u64, 0, 2)
	append(&list, id)
	m^[strings.clone(key)] = list
}

@(private = "file")
id_bucket_remove :: proc(m: ^map[string][dynamic]u64, key: string, id: u64) {
	list, ok := &m^[key]
	if !ok { return }
	for x, i in list^ {
		if x == id {
			ordered_remove(list, i)
			break
		}
	}
	if len(list^) == 0 {
		delete(list^)
		k, _ := delete_key(m, key)
		delete(k)
	}
}

@(private = "file")
named_index_add :: proc(c: ^Named_Cache, idx: int) {
	e := &c.entries[idx]
	c.by_id[e.id] = idx
	id_bucket_add(&c.by_url, cache_url_key(e.url, false), e.id)
	id_bucket_add(&c.by_base_url, cache_url_key(e.url, true), e.id)
}

@(private = "file")
named_index_remove :: proc(c: ^Named_Cache, e: ^Cached_Response) {
	delete_key(&c.by_id, e.id)
	id_bucket_remove(&c.by_url, cache_url_key(e.url, false), e.id)
	id_bucket_remove(&c.by_base_url, cache_url_key(e.url, true), e.id)
}

// Removes sorted entry indices from `c`, compacting `c.entries` from the first removed slot and updating `by_id`.
@(private = "file")
named_remove_indices :: proc(c: ^Named_Cache, indices: []int) {
	if len(indices) == 0 { return }
	first := indices[0]
	for idx in indices {
		named_index_remove(c, &c.entries[idx])
		cached_free(&c.entries[idx])
	}
	write_at := first
	rm_i := 0
	for read_at := first; read_at < len(c.entries); read_at += 1 {
		if rm_i < len(indices) && indices[rm_i] == read_at {
			rm_i += 1
			continue
		}
		if write_at != read_at {
			c.entries[write_at] = c.entries[read_at]
		}
		c.by_id[c.entries[write_at].id] = write_at
		write_at += 1
	}
	resize(&c.entries, write_at)
}

@(private)
named_free :: proc(c: ^Named_Cache) {
	for &e in c.entries { cached_free(&e) }
	delete(c.entries)
	delete(c.by_id)
	for k, v in c.by_url { delete(v); delete(k) }
	delete(c.by_url)
	for k, v in c.by_base_url { delete(v); delete(k) }
	delete(c.by_base_url)
	delete(c.name)
	free(c)
}

@(private = "file")
origin_free :: proc(oc: ^Origin_Caches) {
	for c in oc.caches { named_free(c) }
	delete(oc.caches)
	delete(oc.by_name)
	delete(oc.origin)
	delete(oc.dir)
	free(oc)
}

////////////////////////////////
// Background disk writer (FIFO bodies/deletes + debounced atomic index.wcs snapshots)

@(private = "file")
cache_disk_op_free :: proc(op: ^Cache_Disk_Op) {
	pa := cache_alloc()
	delete(op.origin_key, pa)
	delete(op.cache_name, pa)
	delete(op.dir, pa)
	delete(op.path, pa)
	delete(op.body, pa)
	op^ = {}
}

// (store.mu held) Lazily starts the background writer thread for `store`.
@(private = "file")
cache_writer_ensure_locked :: proc(store: ^Cache_Store) -> ^Cache_Writer {
	if store.writer != nil { return store.writer }
	pa := cache_alloc()
	w := new(Cache_Writer, pa)
	w.store = store
	w.queue = make([dynamic]Cache_Disk_Op, pa)
	prev_alloc := context.allocator
	context.allocator = pa
	w.thread = host.thread_start(cache_writer_main, w, priority = .Below_Normal, name = "wren-cache-writer")
	context.allocator = prev_alloc
	if w.thread == nil {
		delete(w.queue)
		free(w, pa)
		return nil
	}
	store.writer = w
	return w
}

// (store.mu held) Appends a disk op to the writer queue in mutation order.
@(private = "file")
cache_writer_push_locked :: proc(store: ^Cache_Store, op: Cache_Disk_Op, mark_dirty: bool) -> bool {
	w := cache_writer_ensure_locked(store)
	if w == nil { return false }
	sync.mutex_lock(&w.mu)
	append(&w.queue, op)
	if mark_dirty {
		if !w.dirty_pending {
			w.dirty_pending = true
			w.dirty_since = time.tick_now()
		}
	}
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mu)
	return true
}

// (store.mu held) Signals the writer that an origin's index.wcs is dirty.
@(private = "file")
cache_writer_mark_dirty_locked :: proc(store: ^Cache_Store, oc: ^Origin_Caches) -> bool {
	if oc.dir == "" { return true }
	oc.dirty = true
	oc.dirty_gen += 1
	w := cache_writer_ensure_locked(store)
	if w == nil { return false }
	sync.mutex_lock(&w.mu)
	if !w.dirty_pending {
		w.dirty_pending = true
		w.dirty_since = time.tick_now()
		sync.cond_signal(&w.cond)
	}
	sync.mutex_unlock(&w.mu)
	return true
}

// (store.mu NOT held) Executes one body write or body deletion on disk.
@(private = "file")
cache_writer_exec :: proc(store: ^Cache_Store, op: ^Cache_Disk_Op) {
	switch op.kind {
	case .Write_Body:
		if op.dir != "" && !os.exists(op.dir) { _ = os.make_directory_all(op.dir) }
		err := os.write_entire_file(op.path, op.body)
		if err == nil {
			// Body is now durable on disk; release its in-memory write-behind copy if this entry is still live.
			sync.mutex_lock(&store.mu)
			if oc, ok := store.origins[op.origin_key]; ok && oc.dir != "" {
				if c, cok := oc.by_name[op.cache_name]; cok {
					if idx, iok := c.by_id[op.id]; iok {
						e := &c.entries[idx]
						if e.body_resident {
							delete(e.body, cache_alloc())
							e.body = nil
							e.body_resident = false
						}
					}
				}
			}
			sync.mutex_unlock(&store.mu)
		}
	case .Delete_Body:
		_ = os.remove(op.path)
	}
}

@(private = "file")
Index_Snapshot :: struct {
	key:  string,   // process_allocator
	dir:  string,   // process_allocator
	data: []byte,   // process_allocator
}

// (store.mu NOT held) Snapshots all dirty origins under a brief lock, then writes each index.wcs atomically outside the lock.
@(private = "file")
cache_writer_flush_dirty :: proc(store: ^Cache_Store) {
	pa := cache_alloc()
	snaps := make([dynamic]Index_Snapshot, pa)
	defer delete(snaps)

	sync.mutex_lock(&store.mu)
	for k, oc in store.origins {
		if !oc.dirty || oc.dir == "" { continue }
		append(&snaps, Index_Snapshot{
			key  = strings.clone(k, pa),
			dir  = strings.clone(oc.dir, pa),
			data = cache_index_serialize(oc, pa),
		})
		oc.dirty = false
	}
	sync.mutex_unlock(&store.mu)

	for s in snaps {
		_ = os.make_directory_all(s.dir)
		path := strings.concatenate({s.dir, "/index.wcs"}, context.temp_allocator)
		if !base.file_write_atomic(path, s.data) {
			// Restore dirty flag so a later flush or shutdown retries.
			sync.mutex_lock(&store.mu)
			if oc, ok := store.origins[s.key]; ok { oc.dirty = true }
			sync.mutex_unlock(&store.mu)
		}
		delete(s.key, pa)
		delete(s.dir, pa)
		delete(s.data, pa)
	}
}

@(private = "file")
cache_writer_main :: proc(data: rawptr) {
	w := (^Cache_Writer)(data)
	context.allocator = cache_alloc()
	debounce := time.Duration(CACHE_INDEX_DEBOUNCE_MS) * time.Millisecond

	for {
		sync.mutex_lock(&w.mu)
		for {
			if w.head < len(w.queue) { break }
			if w.stopping { break }
			if w.flush_req > w.done_seq { break }
			if w.dirty_pending {
				elapsed := time.tick_since(w.dirty_since)
				if elapsed >= debounce { break }
				sync.cond_wait_with_timeout(&w.cond, &w.mu, debounce - elapsed)
				continue
			}
			sync.cond_wait(&w.cond, &w.mu)
		}

		if w.head < len(w.queue) {
			op := w.queue[w.head]
			w.queue[w.head] = {}
			w.head += 1
			if w.head == len(w.queue) {
				clear(&w.queue)
				w.head = 0
			} else if w.head >= 64 && w.head * 2 >= len(w.queue) {
				n := copy(w.queue[:], w.queue[w.head:])
				resize(&w.queue, n)
				w.head = 0
			}
			sync.mutex_unlock(&w.mu)
			cache_writer_exec(w.store, &op)
			cache_disk_op_free(&op)
			free_all(context.temp_allocator)
			continue
		}

		stopping := w.stopping
		target_flush := w.flush_req
		do_flush := stopping || target_flush > w.done_seq || (w.dirty_pending && time.tick_since(w.dirty_since) >= debounce)
		if do_flush {
			w.dirty_pending = false
		}
		sync.mutex_unlock(&w.mu)

		if do_flush {
			cache_writer_flush_dirty(w.store)
			free_all(context.temp_allocator)
		}

		sync.mutex_lock(&w.mu)
		if target_flush > w.done_seq {
			w.done_seq = target_flush
			sync.cond_broadcast(&w.idle)
		}
		if stopping && w.head == len(w.queue) && !w.dirty_pending {
			sync.mutex_unlock(&w.mu)
			return
		}
		sync.mutex_unlock(&w.mu)
	}
}

// Flushes all queued Cache API disk writes/deletes and dirty index.wcs files to disk synchronously.
cache_store_flush :: proc() {
	if the_pages == nil { return }
	store := &the_pages.cache_store
	sync.mutex_lock(&store.mu)
	w := store.writer
	sync.mutex_unlock(&store.mu)
	if w == nil {
		// No background writer started: flush any dirty origins directly if present.
		cache_writer_flush_dirty(store)
		return
	}
	sync.mutex_lock(&w.mu)
	w.flush_req += 1
	target := w.flush_req
	sync.cond_broadcast(&w.cond)
	for w.done_seq < target && !w.stopping {
		sync.cond_wait(&w.idle, &w.mu)
	}
	sync.mutex_unlock(&w.mu)
}

// Process end: drains and stops the background writer, flushes dirty indices, then frees all in-memory state.
cache_store_shutdown :: proc() {
	if the_pages == nil { return }
	prev_alloc := context.allocator
	context.allocator = cache_alloc()
	defer context.allocator = prev_alloc
	store := &the_pages.cache_store
	sync.mutex_lock(&store.mu)
	w := store.writer
	store.writer = nil
	sync.mutex_unlock(&store.mu)

	if w != nil {
		sync.mutex_lock(&w.mu)
		w.stopping = true
		sync.cond_broadcast(&w.cond)
		sync.mutex_unlock(&w.mu)
		host.thread_join(w.thread)
		for &op in w.queue[w.head:] { cache_disk_op_free(&op) }
		delete(w.queue)
		free(w, cache_alloc())
	} else {
		cache_writer_flush_dirty(store)
	}

	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	for k, oc in store.origins {
		origin_free(oc)
		delete(k)
	}
	delete(store.origins)
	store.origins = nil
}

// <profile>/caches/<origin with every byte outside [a-z0-9.-] as _XX>
@(private)
cache_origin_dir :: proc(profile_dir, origin: string, allocator := context.allocator) -> string {
	if profile_dir == "" { return "" }
	b := strings.builder_make(allocator)
	strings.write_string(&b, profile_dir)
	strings.write_string(&b, "/caches/")
	base.write_file_stem(&b, origin)
	return strings.to_string(b)
}

CACHE_MAGIC :: "WCS2"       // (WCS1: entries without their request's headers, still read)
CACHE_MAGIC_1 :: "WCS1"

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
			wcs_put_str(&b, e.req_headers)
		}
	}
	return b[:]
}

// Reads an index into `oc` (empty); false (and nothing kept) when it is not one.
cache_index_parse :: proc(oc: ^Origin_Caches, data: []byte) -> bool {
	if len(data) < 4 || (string(data[:4]) != CACHE_MAGIC && string(data[:4]) != CACHE_MAGIC_1) { return false }
	v2 := string(data[:4]) == CACHE_MAGIC
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
			if v2 { e.req_headers = wcs_get_str(&r) }
			append(&c.entries, e)
			named_index_add(c, len(c.entries) - 1)
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

// Acquires `store.mu` and returns the caches of `origin` in profile `dir`, loading `index.wcs` WITHOUT holding `store.mu` on first use.
// Caller MUST unlock `store.mu`. Also returns `origin_key` (temp_allocator).
@(private = "file")
origin_caches_lock :: proc(store: ^Cache_Store, dir, origin: string) -> (oc: ^Origin_Caches, key: string) {
	key = strings.concatenate({dir, "\x00", origin}, context.temp_allocator)
	sync.mutex_lock(&store.mu)
	if existing, ok := store.origins[key]; ok { return existing, key }
	sync.mutex_unlock(&store.mu)

	// Load and parse index.wcs completely outside `store.mu` so no other realm stalls on disk I/O.
	pa := cache_alloc()
	prev_alloc := context.allocator
	context.allocator = pa
	defer context.allocator = prev_alloc

	fresh := new(Origin_Caches)
	fresh.origin = strings.clone(origin)
	fresh.dir = cache_origin_dir(dir, origin)
	if fresh.dir != "" {
		if data, err := os.read_entire_file(strings.concatenate({fresh.dir, "/index.wcs"}, context.temp_allocator), context.temp_allocator); err == nil {
			cache_index_parse(fresh, data)
		}
	}
	for c in fresh.caches { fresh.by_name[c.name] = c }

	sync.mutex_lock(&store.mu)
	if existing, ok := store.origins[key]; ok {
		origin_free(fresh)
		return existing, key
	}
	if store.origins == nil { store.origins = make(map[string]^Origin_Caches) }
	store.origins[strings.clone(key)] = fresh
	return fresh, key
}

@(private)
body_path :: proc(oc: ^Origin_Caches, id: u64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%d.body", oc.dir, id, allocator = allocator)
}

@(private)
find_cache :: proc(oc: ^Origin_Caches, name: string) -> (^Named_Cache, int) {
	if c, ok := oc.by_name[name]; ok {
		for x, i in oc.caches { if x == c { return c, i } }
	}
	return nil, -1
}

@(private = "file")
find_cache_fast :: proc(oc: ^Origin_Caches, name: string) -> ^Named_Cache {
	return oc.by_name[name] or_else nil
}

// URL without its fragment (and its query with ignore_search): what matching compares.
@(private)
cache_url_key :: proc(u: string, ignore_search: bool) -> string {
	s := u
	if i := strings.index_byte(s, '#'); i >= 0 { s = s[:i] }
	if ignore_search { if i := strings.index_byte(s, '?'); i >= 0 { s = s[:i] } }
	return s
}

cache_entry_matches :: proc(e: ^Cached_Response, url, method: string, q: Cache_Query, req_headers := "") -> bool {
	if !q.ignore_method && method != "GET" && method != "" { return false }
	if cache_url_key(e.url, q.ignore_search) != cache_url_key(url, q.ignore_search) { return false }
	if q.ignore_vary { return true }
	return cache_vary_matches(e.headers, e.req_headers, req_headers)
}

// Cache "request matches cached item": every field the response's Vary names has the same value (combined, absent
// alike) in both requests; Vary: * never matches.
cache_vary_matches :: proc(response_headers, stored_request, request: string) -> bool {
	vary := header_combined(response_headers, "vary", context.temp_allocator)
	rest := vary
	for field in strings.split_iterator(&rest, ",") {
		name := strings.trim_space(field)
		if name == "" { continue }
		if name == "*" { return false }
		if header_combined(stored_request, name, context.temp_allocator) != header_combined(request, name, context.temp_allocator) { return false }
	}
	return true
}

// Every value of header `name` in "Name: value" lines, joined with ", " ("" when absent).
@(private)
header_combined :: proc(lines: string, name: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	text := lines
	n := 0
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_right(line, "\r")
		colon := strings.index_byte(l, ':')
		if colon <= 0 || !base.ascii_equal_fold(strings.trim_space(l[:colon]), name) { continue }
		if n > 0 { strings.write_string(&b, ", ") }
		strings.write_string(&b, strings.trim_space(l[colon + 1:]))
		n += 1
	}
	return strings.to_string(b)
}

////////////////////////////////
// Operations (thread-safe; never hold cache_store.mu during disk I/O)

cache_open :: proc(dir, origin, name: string) {
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	prev_alloc := context.allocator
	context.allocator = cache_alloc()
	flush_sync := false
	if find_cache_fast(oc, name) == nil {
		c := new(Named_Cache)
		c.name = strings.clone(name)
		append(&oc.caches, c)
		oc.by_name[c.name] = c
		flush_sync = !cache_writer_mark_dirty_locked(store, oc)
	}
	context.allocator = prev_alloc
	sync.mutex_unlock(&store.mu)
	if flush_sync { cache_writer_flush_dirty(store) }
}

cache_has :: proc(dir, origin, name: string) -> bool {
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	defer sync.mutex_unlock(&store.mu)
	return find_cache_fast(oc, name) != nil
}

cache_delete_named :: proc(dir, origin, name: string) -> bool {
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	prev_alloc := context.allocator
	context.allocator = cache_alloc()
	c, i := find_cache(oc, name)
	if c == nil {
		context.allocator = prev_alloc
		sync.mutex_unlock(&store.mu)
		return false
	}
	sync_ops := make([dynamic]Cache_Disk_Op, context.temp_allocator)
	for e in c.entries {
		oc.bytes -= e.size
		if oc.dir != "" {
			op := Cache_Disk_Op{kind = .Delete_Body, path = body_path(oc, e.id, cache_alloc())}
			if !cache_writer_push_locked(store, op, false) { append(&sync_ops, op) }
		}
	}
	delete_key(&oc.by_name, c.name)
	ordered_remove(&oc.caches, i)
	named_free(c)
	flush_sync := !cache_writer_mark_dirty_locked(store, oc)
	context.allocator = prev_alloc
	sync.mutex_unlock(&store.mu)

	for &op in sync_ops {
		cache_writer_exec(store, &op)
		cache_disk_op_free(&op)
	}
	if flush_sync { cache_writer_flush_dirty(store) }
	return true
}

// The names, in creation order, "\n"-separated (temporary allocator).
cache_names :: proc(dir, origin: string) -> string {
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	defer sync.mutex_unlock(&store.mu)
	b := strings.builder_make(context.temp_allocator)
	for c, i in oc.caches { if i > 0 { strings.write_byte(&b, '\n') }; strings.write_string(&b, c.name) }
	return strings.to_string(b)
}

// The ids of the entries of cache `name` matching (all of them with url = ""), in insertion order (temporary).
cache_match_ids :: proc(dir, origin, name, url, method: string, q: Cache_Query, req_headers := "") -> []u64 {
	if url != "" && !q.ignore_method && method != "GET" && method != "" { return nil }
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	defer sync.mutex_unlock(&store.mu)
	c := find_cache_fast(oc, name)
	if c == nil { return nil }
	out := make([dynamic]u64, context.temp_allocator)
	if url == "" {
		for &e in c.entries { append(&out, e.id) }
		return out[:]
	}
	candidates: []u64
	if q.ignore_search {
		if list, ok := c.by_base_url[cache_url_key(url, true)]; ok { candidates = list[:] }
	} else {
		if list, ok := c.by_url[cache_url_key(url, false)]; ok { candidates = list[:] }
	}
	for id in candidates {
		idx, ok := c.by_id[id]
		if !ok { continue }
		if cache_entry_matches(&c.entries[idx], url, method, q, req_headers) { append(&out, id) }
	}
	return out[:]
}

// The header lines of an entry's request (temporary); ok = false when it is gone.
cache_entry_request_headers :: proc(dir, origin, name: string, id: u64) -> (string, bool) {
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	defer sync.mutex_unlock(&store.mu)
	c := find_cache_fast(oc, name)
	if c == nil { return "", false }
	idx, ok := c.by_id[id]
	if !ok { return "", false }
	return strings.clone(c.entries[idx].req_headers, context.temp_allocator), true
}

// An entry's request and response head (copies in the temporary allocator); ok = false when it is gone.
cache_entry_head :: proc(dir, origin, name: string, id: u64) -> (e: Cached_Response, ok: bool) {
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	defer sync.mutex_unlock(&store.mu)
	c := find_cache_fast(oc, name)
	if c == nil { return }
	idx, found := c.by_id[id]
	if !found { return }
	x := &c.entries[idx]
	t := context.temp_allocator
	return Cached_Response{id = x.id, url = strings.clone(x.url, t), method = strings.clone(x.method, t), status = x.status,
		status_text = strings.clone(x.status_text, t), response_url = strings.clone(x.response_url, t), headers = strings.clone(x.headers, t), size = x.size}, true
}

// An entry's body (allocated with `allocator`); ok = false when it is gone or unreadable.
// Disk reads execute after releasing `cache_store.mu` so no other realm blocks on disk I/O.
cache_entry_body :: proc(dir, origin, name: string, id: u64, allocator := context.allocator) -> (body: []byte, ok: bool) {
	out_alloc := allocator
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	c := find_cache_fast(oc, name)
	if c == nil {
		sync.mutex_unlock(&store.mu)
		return
	}
	idx, found := c.by_id[id]
	if !found {
		sync.mutex_unlock(&store.mu)
		return
	}
	x := &c.entries[idx]
	if x.body_resident || oc.dir == "" {
		out := make([]byte, len(x.body), out_alloc)
		copy(out, x.body)
		sync.mutex_unlock(&store.mu)
		return out, true
	}
	path := body_path(oc, id, context.temp_allocator)
	sync.mutex_unlock(&store.mu)
	data, err := os.read_entire_file(path, out_alloc)
	return data, err == nil
}

Cache_Put_Error :: enum u8 { None, No_Cache, Quota }

// Stores an entry (replacing those that match its request), creating cache `name` if it went away meanwhile.
// Uses the URL index (single candidate scan instead of double O(N) scan) and offloads body/index writes to Cache_Writer.
cache_put :: proc(dir, origin, name: string, e: Cached_Response, body: []byte, max_bytes: i64) -> Cache_Put_Error {
	store := &the_pages.cache_store
	oc, origin_key := origin_caches_lock(store, dir, origin)
	pa := cache_alloc()
	prev_alloc := context.allocator
	context.allocator = pa

	c := find_cache_fast(oc, name)
	if c == nil {
		c = new(Named_Cache)
		c.name = strings.clone(name)
		append(&oc.caches, c)
		oc.by_name[c.name] = c
	}

	url_key := cache_url_key(e.url, false)
	matched_indices := make([dynamic]int, context.temp_allocator)
	freed: i64
	if list, ok := c.by_url[url_key]; ok {
		for id in list {
			idx, iok := c.by_id[id]
			if !iok { continue }
			if cache_entry_matches(&c.entries[idx], e.url, "GET", {}, e.req_headers) {
				freed += c.entries[idx].size
				append(&matched_indices, idx)
			}
		}
	}
	if oc.bytes - freed + i64(len(body)) > max_bytes {
		context.allocator = prev_alloc
		sync.mutex_unlock(&store.mu)
		return .Quota
	}

	sync_ops := make([dynamic]Cache_Disk_Op, context.temp_allocator)
	if len(matched_indices) > 0 {
		slice.sort(matched_indices[:])
		for idx in matched_indices {
			x := &c.entries[idx]
			oc.bytes -= x.size
			if oc.dir != "" {
				op := Cache_Disk_Op{kind = .Delete_Body, path = body_path(oc, x.id, pa)}
				if !cache_writer_push_locked(store, op, false) { append(&sync_ops, op) }
			}
		}
		named_remove_indices(c, matched_indices[:])
	}

	oc.next += 1
	ne := Cached_Response{
		id            = oc.next,
		url           = strings.clone(url_key),
		method        = strings.clone("GET"),
		status        = e.status,
		status_text   = strings.clone(e.status_text),
		response_url  = strings.clone(e.response_url),
		headers       = strings.clone(e.headers),
		size          = i64(len(body)),
		req_headers   = strings.clone(e.req_headers),
		body_resident = true,
	}
	if len(body) > 0 {
		ne.body = make([]byte, len(body))
		copy(ne.body, body)
	}
	append(&c.entries, ne)
	named_index_add(c, len(c.entries) - 1)
	oc.bytes += ne.size

	flush_sync := false
	if oc.dir != "" {
		oc.dirty = true
		oc.dirty_gen += 1
		body_copy: []byte
		if len(body) > 0 {
			body_copy = make([]byte, len(body), pa)
			copy(body_copy, body)
		}
		wop := Cache_Disk_Op{
			kind       = .Write_Body,
			origin_key = strings.clone(origin_key, pa),
			cache_name = strings.clone(name, pa),
			dir        = strings.clone(oc.dir, pa),
			path       = body_path(oc, ne.id, pa),
			id         = ne.id,
			body       = body_copy,
		}
		if !cache_writer_push_locked(store, wop, true) {
			append(&sync_ops, wop)
			flush_sync = true
		}
	}

	context.allocator = prev_alloc
	sync.mutex_unlock(&store.mu)

	for &op in sync_ops {
		cache_writer_exec(store, &op)
		cache_disk_op_free(&op)
	}
	if flush_sync { cache_writer_flush_dirty(store) }
	return .None
}

// Removes the entries matching; true when there were some.
cache_delete_entries :: proc(dir, origin, name, url, method: string, q: Cache_Query, req_headers := "") -> bool {
	if url != "" && !q.ignore_method && method != "GET" && method != "" { return false }
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	pa := cache_alloc()
	prev_alloc := context.allocator
	context.allocator = pa

	c := find_cache_fast(oc, name)
	if c == nil {
		context.allocator = prev_alloc
		sync.mutex_unlock(&store.mu)
		return false
	}

	matched_indices := make([dynamic]int, context.temp_allocator)
	if url == "" {
		for &x, i in c.entries {
			if cache_entry_matches(&x, url, method, q, req_headers) { append(&matched_indices, i) }
		}
	} else {
		candidates: []u64
		if q.ignore_search {
			if list, ok := c.by_base_url[cache_url_key(url, true)]; ok { candidates = list[:] }
		} else {
			if list, ok := c.by_url[cache_url_key(url, false)]; ok { candidates = list[:] }
		}
		for id in candidates {
			idx, ok := c.by_id[id]
			if !ok { continue }
			if cache_entry_matches(&c.entries[idx], url, method, q, req_headers) { append(&matched_indices, idx) }
		}
	}

	if len(matched_indices) == 0 {
		context.allocator = prev_alloc
		sync.mutex_unlock(&store.mu)
		return false
	}

	slice.sort(matched_indices[:])
	sync_ops := make([dynamic]Cache_Disk_Op, context.temp_allocator)
	for idx in matched_indices {
		x := &c.entries[idx]
		oc.bytes -= x.size
		if oc.dir != "" {
			op := Cache_Disk_Op{kind = .Delete_Body, path = body_path(oc, x.id, pa)}
			if !cache_writer_push_locked(store, op, false) { append(&sync_ops, op) }
		}
	}
	named_remove_indices(c, matched_indices[:])
	flush_sync := !cache_writer_mark_dirty_locked(store, oc)

	context.allocator = prev_alloc
	sync.mutex_unlock(&store.mu)

	for &op in sync_ops {
		cache_writer_exec(store, &op)
		cache_disk_op_free(&op)
	}
	if flush_sync { cache_writer_flush_dirty(store) }
	return true
}

// Every cache of a storage key removed ("Clear site data").
cache_clear_key :: proc(dir, key: string) {
	names := strings.split(cache_names(dir, key), "\n", context.temp_allocator)
	for n in names { if n != "" { cache_delete_named(dir, key, n) } }
}

// The storage keys that have caches on the disk (temporary), from the folder names (cache_origin_dir's escaping).
cache_keys :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if dir == "" { return nil }
	if dirs, err := os.read_all_directory_by_path(strings.concatenate({dir, "/caches"}, context.temp_allocator), context.temp_allocator); err == nil {
		for d in dirs { if d.type == .Directory { if k, ok := key_of_file(d.name, ""); ok { append(&out, k) } } }
	}
	return out[:]
}

// Bytes the Cache API keeps for an origin (StorageManager.estimate).
cache_usage :: proc(dir, origin: string) -> i64 {
	store := &the_pages.cache_store
	oc, _ := origin_caches_lock(store, dir, origin)
	defer sync.mutex_unlock(&store.mu)
	return oc.bytes
}
