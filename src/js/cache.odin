package js

// The bytecode cache: compiled scripts (QuickJS bytecode, as the engine serializes it), shared by every realm of the
// process (pages, tabs, workers, compilation threads), keyed by SHA-256 of
//   engine version | flags | script URL | source
// so a change of any of them is a miss (the URL is in the bytecode's stack traces).
//   * Memory: an LRU by size (javascript.bytecode_cache.memory_bytes).
//   * Disk (profile folder js-cache): "WRENQBC1" | HMAC-SHA256(key, magic | cache key | payload) | payload, with a
//     random key of the profile protected by DPAPI (wasm.Disk_Cache: the Wasm code cache's scheme). A wrong MAC or format
//     deletes the file. Writes go to a background thread (temporary file, then rename); the folder is trimmed to
//     javascript.bytecode_cache.disk_max_bytes, least recently used first.
// Bytecode only ever runs inside the engine's sandbox; the MAC keeps one profile's cache from being fed another's.
// Thread-safe.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:wasm"
import "wb:base"

Cache_Settings :: struct {
	memory_bytes:     i64,
	disk:             bool,
	disk_max_bytes:   i64,
	min_source_bytes: int,
	profile_dir:      string,
}

Key :: wasm.Digest

Cache_Stats :: struct {
	lookups, memory_hits, disk_hits, stores, disk_writes, disk_rejects, evictions: int,
	entries, bytes: int,   // bytecode in memory now
}

@(private) DISK_MAGIC :: "WRENQBC1"
@(private) DISK_EXT :: ".qbc"

@(private)
Entry :: struct {
	code:     []byte,
	last_use: u64,
}

@(private)
Cache :: struct {
	lock:      sync.Mutex,
	started:   bool,
	settings:  Cache_Settings,
	entries:   map[Key]Entry,
	total:     i64,
	clock:     u64,
	disk:      bool,
	files:     wasm.Disk_Cache,
	stats:     Cache_Stats,
}

@(private)
cache: Cache

// Starts the cache (idempotent: the first settings win until cache_stop).
cache_start :: proc(s: Cache_Settings) {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	if cache.started { return }
	context.allocator = base.process_allocator()
	cache.started = true
	cache.settings = s
	cache.settings.profile_dir = strings.clone(s.profile_dir)
	if s.disk && s.profile_dir != "" {
		dir, _ := filepath.join({s.profile_dir, "js-cache"}, context.temp_allocator)
		cache.files = {magic = DISK_MAGIC, ext = DISK_EXT, max_bytes = s.disk_max_bytes}
		cache.disk = wasm.disk_start(&cache.files, dir)
	}
}

// Stops the writer (after it wrote what was queued) and frees everything.
cache_stop :: proc() {
	sync.mutex_lock(&cache.lock)
	if !cache.started { sync.mutex_unlock(&cache.lock); return }
	sync.mutex_unlock(&cache.lock)
	wasm.disk_stop(&cache.files)
	context.allocator = base.process_allocator()
	sync.mutex_lock(&cache.lock)
	for _, e in cache.entries { delete(e.code) }
	delete(cache.entries)
	delete(cache.settings.profile_dir)
	cache = {}
}

cache_stats :: proc() -> Cache_Stats {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	s := cache.stats
	s.entries, s.bytes = len(cache.entries), int(cache.total)
	s.disk_writes, s.disk_rejects = sync.atomic_load(&cache.files.writes), sync.atomic_load(&cache.files.rejects)
	return s
}

// Waits until the disk writer is idle: nothing queued and nothing being written (tests).
cache_flush :: proc() { wasm.disk_flush(&cache.files) }

// Whether a script of this size is worth caching.
cacheable :: proc(source_len: int) -> bool {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	return cache.started && (cache.settings.memory_bytes > 0 || cache.disk) && source_len >= cache.settings.min_source_bytes
}

// The cache key of a script.
key_of :: proc(engine_version: string, flags: i32, url: string, source: []byte) -> Key {
	f := transmute([4]u8)flags
	zero := [1]u8{0}
	k, _ := wasm.digest(transmute([]byte)engine_version, f[:], transmute([]byte)url, zero[:], source)
	return k
}

// The bytecode stored under `key` (a copy in `allocator`), or nil.
lookup :: proc(key: Key, allocator := context.allocator) -> []byte {
	sync.mutex_lock(&cache.lock)
	if !cache.started { sync.mutex_unlock(&cache.lock); return nil }
	cache.stats.lookups += 1
	cache.clock += 1
	if e, ok := &cache.entries[key]; ok {
		e.last_use = cache.clock
		cache.stats.memory_hits += 1
		out := slice.clone(e.code, allocator)
		sync.mutex_unlock(&cache.lock)
		return out
	}
	disk := cache.disk
	sync.mutex_unlock(&cache.lock)
	if !disk { return nil }
	code := disk_load(key)
	if code == nil { return nil }
	sync.mutex_lock(&cache.lock)
	cache.stats.disk_hits += 1
	sync.mutex_unlock(&cache.lock)
	memory_put(key, code)
	return slice.clone(code, allocator)
}

// Stores bytecode (copied) in memory and, when it was not on disk already, queues it for the disk.
store :: proc(key: Key, code: []byte) {
	if len(code) == 0 { return }
	sync.mutex_lock(&cache.lock)
	if !cache.started { sync.mutex_unlock(&cache.lock); return }
	cache.stats.stores += 1
	disk := cache.disk
	sync.mutex_unlock(&cache.lock)
	memory_put(key, code)
	if disk {
		path := wasm.disk_path(&cache.files, key)
		defer delete(path, base.process_allocator())
		if !os.exists(path) { wasm.disk_queue(&cache.files, path, key, slice.clone(code, base.process_allocator())) }
	}
}

@(private)
memory_put :: proc(key: Key, code: []byte) {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	limit := cache.settings.memory_bytes
	if limit <= 0 || i64(len(code)) > limit { return }
	context.allocator = base.process_allocator()
	cache.clock += 1
	if e, ok := &cache.entries[key]; ok { e.last_use = cache.clock; return }
	cache.entries[key] = Entry{code = slice.clone(code), last_use = cache.clock}
	cache.total += i64(len(code))
	for cache.total > limit {
		oldest: Key
		best := max(u64)
		for k, e in cache.entries { if e.last_use < best { best = e.last_use; oldest = k } }
		e := cache.entries[oldest]
		cache.total -= i64(len(e.code))
		delete(e.code)
		delete_key(&cache.entries, oldest)
		cache.stats.evictions += 1
	}
}

// Drops the memory cache (memory pressure, tests).
cache_clear_memory :: proc() {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	for _, e in cache.entries { delete(e.code, base.process_allocator()) }
	clear(&cache.entries)
	cache.total = 0
}

@(private)
disk_load :: proc(key: Key) -> []byte {
	path := wasm.disk_path(&cache.files, key)
	defer delete(path, base.process_allocator())
	data, payload := wasm.disk_read(&cache.files, path, key)
	if data == nil { return nil }
	defer delete(data, base.process_allocator())
	return slice.clone(payload, context.temp_allocator)
}
