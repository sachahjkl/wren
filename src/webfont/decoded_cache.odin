package webfont

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:sync"

// Fonts already decoded, for the whole process: a page that comes back, another tab of the same site, use the sfnt
// of a WOFF / WOFF2 without unpacking it again (Brotli and the WOFF2 transforms are the costly part of a web font that
// comes from the HTTP cache). Keyed by the URL *and* a hash of the downloaded bytes: a font that changed on its server
// is a new entry, never the old one. Least recently used out first, within the bytes the caller allows.

@(private = "file")
Decoded :: struct {
	key:        string,
	sfnt:       []byte,
	format:     Format,
	prev, next: ^Decoded,
}

@(private = "file")
Decoded_Cache :: struct {
	mu:         sync.Mutex,
	entries:    map[string]^Decoded,
	head, tail: ^Decoded,
	bytes:      int,
	hits:       int,
	misses:     int,
}

@(private = "file")
cache: Decoded_Cache

// Decodes `data` (downloaded from `url`) like `decode`, through the cache. The sfnt returned is the caller's (a copy
// in `allocator`). `cache_bytes` <= 0: no cache. `cached`: it was decoded before.
decode_cached :: proc(url: string, data: []byte, max_bytes: int, cache_bytes: int, allocator := context.allocator) -> (sfnt: []byte, format: Format, err: Error, cached: bool) {
	if cache_bytes <= 0 {
		sfnt, format, err = decode(data, max_bytes, allocator)
		return
	}
	a := runtime.heap_allocator()
	key := fmt.tprintf("%016x %d %s", xxhash.XXH3_64_default(data), len(data), url)
	sync.mutex_lock(&cache.mu)
	if d, ok := cache.entries[key]; ok && len(d.sfnt) <= max_bytes {
		unlink(d)
		push_front(d)
		cache.hits += 1
		sfnt = make([]byte, len(d.sfnt), allocator)
		copy(sfnt, d.sfnt)
		format = d.format
		sync.mutex_unlock(&cache.mu)
		return sfnt, format, .None, true
	}
	cache.misses += 1
	sync.mutex_unlock(&cache.mu)

	sfnt, format, err = decode(data, max_bytes, allocator)
	if err != .None || len(sfnt) > cache_bytes { return }

	d := new(Decoded, a)
	d.key = fmt.aprintf("%s", key, allocator = a)
	d.sfnt = make([]byte, len(sfnt), a)
	copy(d.sfnt, sfnt)
	d.format = format
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	if cache.entries == nil { cache.entries = make(map[string]^Decoded, a) }
	if old, ok := cache.entries[d.key]; ok { drop(old) }   // (decoded twice at once)
	cache.entries[d.key] = d
	push_front(d)
	cache.bytes += len(d.sfnt)
	for cache.bytes > cache_bytes && cache.tail != nil { drop(cache.tail) }
	return
}

// Hits and misses so far, and what the cache holds.
decoded_cache_stats :: proc() -> (hits, misses, entries, bytes: int) {
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	return cache.hits, cache.misses, len(cache.entries), cache.bytes
}

// Frees everything (process exit, or "clear the caches").
decoded_cache_clear :: proc() {
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	for cache.head != nil { drop(cache.head) }
	delete(cache.entries)
	cache.entries = nil
}

@(private = "file")
drop :: proc(d: ^Decoded) {
	a := runtime.heap_allocator()
	unlink(d)
	delete_key(&cache.entries, d.key)
	cache.bytes -= len(d.sfnt)
	delete(d.key, a)
	delete(d.sfnt, a)
	free(d, a)
}

@(private = "file")
push_front :: proc(d: ^Decoded) {
	d.prev, d.next = nil, cache.head
	if cache.head != nil { cache.head.prev = d } else { cache.tail = d }
	cache.head = d
}

@(private = "file")
unlink :: proc(d: ^Decoded) {
	if d.prev != nil { d.prev.next = d.next } else if cache.head == d { cache.head = d.next }
	if d.next != nil { d.next.prev = d.prev } else if cache.tail == d { cache.tail = d.prev }
	d.prev, d.next = nil, nil
}
