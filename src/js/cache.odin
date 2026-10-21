package js

// The bytecode cache: compiled scripts (QuickJS bytecode, as the engine serializes it), shared by every realm of the
// process (pages, tabs, workers, compilation threads), keyed by SHA-256 of
//   engine version | flags | script URL | source
// so a change of any of them is a miss (the URL is in the bytecode's stack traces).
//   * Memory: an LRU by size (javascript.bytecode_cache.memory_bytes).
//   * Disk (profile folder js-cache): "WRENQBC1" | HMAC-SHA256(key, magic | cache key | payload) | payload, with a
//     random key of the profile protected by DPAPI (the same scheme as the Wasm code cache). A wrong MAC or format
//     deletes the file. Writes go to a background thread (temporary file, then rename); the folder is trimmed to
//     javascript.bytecode_cache.disk_max_bytes, least recently used first.
// Bytecode only ever runs inside the engine's sandbox; the MAC keeps one profile's cache from being fed another's.
// Thread-safe.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
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
@(private) KEY_FILE :: "cache-key.dpapi"

@(private)
Entry :: struct {
	code:     []byte,
	last_use: u64,
}

@(private)
Write_Job :: struct {
	path:    string,
	key:     Key,
	payload: []byte,
}

@(private)
Cache :: struct {
	lock:      sync.Mutex,
	started:   bool,
	settings:  Cache_Settings,
	entries:   map[Key]Entry,
	total:     i64,
	clock:     u64,
	dir:       string,
	mac_key:   [32]u8,
	disk:      bool,
	stats:     Cache_Stats,
	qlock:     sync.Mutex,
	qcond:     sync.Cond,
	queue:     [dynamic]Write_Job,
	writing:   int,   // jobs taken off the queue and not finished (under qlock)
	stop:      bool,
	writer:    ^thread.Thread,
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
		cache.dir, _ = filepath.join({s.profile_dir, "js-cache"})
		cache.disk = disk_key_load(cache.dir)
		if cache.disk {
			cache.stop = false
			cache.writer = thread.create_and_start_with_data(nil, writer_main)
		}
	}
}

// Stops the writer (after it wrote what was queued) and frees everything.
cache_stop :: proc() {
	sync.mutex_lock(&cache.lock)
	if !cache.started { sync.mutex_unlock(&cache.lock); return }
	writer := cache.writer
	cache.writer = nil
	sync.mutex_unlock(&cache.lock)
	if writer != nil {
		sync.mutex_lock(&cache.qlock)
		cache.stop = true
		sync.cond_broadcast(&cache.qcond)
		sync.mutex_unlock(&cache.qlock)
		thread.join(writer)
		thread.destroy(writer)
	}
	context.allocator = base.process_allocator()
	sync.mutex_lock(&cache.lock)
	for _, e in cache.entries { delete(e.code) }
	delete(cache.entries)
	delete(cache.dir)
	delete(cache.settings.profile_dir)
	for j in cache.queue { delete(j.path); delete(j.payload) }
	delete(cache.queue)
	cache = {}
}

cache_stats :: proc() -> Cache_Stats {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	s := cache.stats
	s.entries, s.bytes = len(cache.entries), int(cache.total)
	return s
}

// Waits until the disk writer is idle: nothing queued and nothing being written (tests).
cache_flush :: proc() {
	for {
		sync.mutex_lock(&cache.qlock)
		idle := len(cache.queue) == 0 && cache.writing == 0
		sync.mutex_unlock(&cache.qlock)
		if idle { break }
		time.sleep(time.Millisecond)
	}
}

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
		path := disk_path(key)
		if os.exists(path) { delete(path, base.process_allocator()); return }
		sync.mutex_lock(&cache.qlock)
		append(&cache.queue, Write_Job{path = path, key = key, payload = slice.clone(code, base.process_allocator())})
		sync.cond_signal(&cache.qcond)
		sync.mutex_unlock(&cache.qlock)
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
disk_path :: proc(key: Key) -> string {
	hex := strings.builder_make(context.temp_allocator)
	for b in key { fmt.sbprintf(&hex, "%02x", b) }
	strings.write_string(&hex, DISK_EXT)
	p, _ := filepath.join({cache.dir, strings.to_string(hex)}, base.process_allocator())
	return p
}

@(private)
disk_key_load :: proc(dir: string) -> bool {
	_ = os.make_directory_all(dir)
	path, perr := filepath.join({dir, KEY_FILE}, context.temp_allocator)
	if perr != nil { return false }
	if blob, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		if key, ok := wasm.unprotect_key(blob, context.temp_allocator); ok && len(key) == 32 {
			copy(cache.mac_key[:], key)
			return true
		}
	}
	if !wasm.random_bytes(cache.mac_key[:]) { return false }
	blob, ok := wasm.protect_key(cache.mac_key[:], context.temp_allocator)
	if !ok { return false }
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, blob); err != nil { return false }
	if err := os.rename(tmp, path); err != nil { _ = os.remove(tmp); return false }
	return true
}

@(private)
disk_mac :: proc(key: Key, payload: []byte) -> (wasm.Digest, bool) {
	key := key
	return wasm.digest(transmute([]byte)string(DISK_MAGIC), key[:], payload, key = cache.mac_key[:])
}

@(private)
disk_load :: proc(key: Key) -> []byte {
	path := disk_path(key)
	defer delete(path, base.process_allocator())
	data, err := os.read_entire_file(path, base.process_allocator())
	if err != nil { return nil }
	head := len(DISK_MAGIC) + 32
	if len(data) <= head || string(data[:len(DISK_MAGIC)]) != DISK_MAGIC {
		delete(data, base.process_allocator())
		disk_reject(path)
		return nil
	}
	mac, ok := disk_mac(key, data[head:])
	if !ok || !wasm.digests_equal(mac[:], data[len(DISK_MAGIC):head]) {
		delete(data, base.process_allocator())
		disk_reject(path)
		return nil
	}
	now := time.now()
	_ = os.change_times(path, now, now)
	out := slice.clone(data[head:], context.temp_allocator)
	delete(data, base.process_allocator())
	return out
}

@(private)
disk_reject :: proc(path: string) {
	_ = os.remove(path)
	sync.mutex_lock(&cache.lock)
	cache.stats.disk_rejects += 1
	sync.mutex_unlock(&cache.lock)
}

@(private)
writer_main :: proc(_: rawptr) {
	context.allocator = base.process_allocator()
	for {
		sync.mutex_lock(&cache.qlock)
		for len(cache.queue) == 0 && !cache.stop { sync.cond_wait(&cache.qcond, &cache.qlock) }
		if len(cache.queue) == 0 {
			sync.mutex_unlock(&cache.qlock)
			return
		}
		job := pop_front(&cache.queue)
		cache.writing += 1
		sync.mutex_unlock(&cache.qlock)
		if disk_write(job) {
			sync.mutex_lock(&cache.lock)
			cache.stats.disk_writes += 1
			sync.mutex_unlock(&cache.lock)
			disk_trim()
		}
		delete(job.path)
		delete(job.payload)
		free_all(context.temp_allocator)
		sync.mutex_lock(&cache.qlock)
		cache.writing -= 1   // after the stats: cache_flush returns once they are up to date
		sync.mutex_unlock(&cache.qlock)
	}
}

@(private)
disk_write :: proc(job: Write_Job) -> bool {
	mac, ok := disk_mac(job.key, job.payload)
	if !ok { return false }
	head := len(DISK_MAGIC) + 32
	buf := make([]byte, head + len(job.payload))
	defer delete(buf)
	copy(buf, DISK_MAGIC)
	copy(buf[len(DISK_MAGIC):], mac[:])
	copy(buf[head:], job.payload)
	nonce: [8]u8
	wasm.random_bytes(nonce[:])
	tmp := fmt.tprintf("%s.%x.tmp", job.path, transmute(u64)nonce)
	if we := os.write_entire_file(tmp, buf); we != nil { _ = os.remove(tmp); return false }
	if re := os.rename(tmp, job.path); re != nil { _ = os.remove(tmp); return false }
	return true
}

@(private)
disk_trim :: proc() {
	infos, err := os.read_all_directory_by_path(cache.dir, context.temp_allocator)
	if err != nil { return }
	entries := make([dynamic]os.File_Info, context.temp_allocator)
	total: i64
	for fi in infos {
		if strings.has_suffix(fi.name, ".tmp") && time.diff(fi.modification_time, time.now()) > time.Hour { _ = os.remove(fi.fullpath); continue }
		if !strings.has_suffix(fi.name, DISK_EXT) { continue }
		append(&entries, fi)
		total += fi.size
	}
	if total <= cache.settings.disk_max_bytes { return }
	slice.sort_by(entries[:], proc(a, b: os.File_Info) -> bool { return time.diff(a.modification_time, b.modification_time) > 0 })
	for fi in entries {
		if total <= cache.settings.disk_max_bytes { break }
		if os.remove(fi.fullpath) == nil { total -= fi.size }
	}
}
