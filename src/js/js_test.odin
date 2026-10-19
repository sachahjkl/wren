package js

// The bytecode cache (memory LRU, authenticated disk entries, corrupted files), per-site enabling, the time zone.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

@(test)
cache_memory_and_disk :: proc(t: ^testing.T) {
	dir := filepath.join({os.get_env("TEMP", context.temp_allocator), fmt.tprintf("wren-js-cache-test-%d", time.now()._nsec)}, context.temp_allocator) or_else ""
	defer os.remove_all(dir)
	cache_start({memory_bytes = 64, disk = true, disk_max_bytes = 1 << 20, min_source_bytes = 4, profile_dir = dir})
	k1 := key_of("v1", 0, "https://a.example/x.js", transmute([]byte)string("let x = 1"))
	k2 := key_of("v1", 0, "https://a.example/y.js", transmute([]byte)string("let x = 1"))
	k3 := key_of("v2", 0, "https://a.example/x.js", transmute([]byte)string("let x = 1"))
	testing.expect(t, k1 != k2 && k1 != k3)   // the URL and the engine version are part of the key
	testing.expect(t, cacheable(4) && !cacheable(3))
	testing.expect(t, lookup(k1, context.temp_allocator) == nil)
	code := transmute([]byte)string("0123456789abcdef0123456789abcdef")
	store(k1, code)
	got := lookup(k1, context.temp_allocator)
	testing.expect(t, string(got) == string(code))
	// a second entry evicts the first from memory (64 bytes): it comes back from the disk
	store(k2, code)
	cache_flush()
	cache_clear_memory()
	got = lookup(k1, context.temp_allocator)
	testing.expect(t, string(got) == string(code))
	st := cache_stats()
	testing.expect(t, st.disk_hits >= 1)
	testing.expect(t, st.disk_writes >= 2)
	// a corrupted file is refused and deleted
	path := disk_path(k2)
	defer delete(path)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	data[len(data) - 1] ~= 0xff
	_ = os.write_entire_file(path, data)
	cache_clear_memory()
	testing.expect(t, lookup(k2, context.temp_allocator) == nil)
	testing.expect(t, !os.exists(path))
	testing.expect(t, cache_stats().disk_rejects >= 1)
	cache_stop()
	// another key of the profile: the old entries no longer match (the MAC key is created once and kept)
	cache_start({memory_bytes = 64, disk = true, disk_max_bytes = 1 << 20, min_source_bytes = 4, profile_dir = dir})
	got = lookup(k1, context.temp_allocator)
	testing.expect(t, string(got) == string(code))   // same profile, same key: still valid
	cache_stop()
}

@(test)
sites :: proc(t: ^testing.T) {
	s := settings_default()
	defer settings_destroy(&s)
	testing.expect(t, enabled_for(&s, "example.com"))
	delete(s.sites_disabled)
	s.sites_disabled = split_sites("ads.example, *.tracker.test")
	testing.expect(t, !enabled_for(&s, "ads.example"))
	testing.expect(t, !enabled_for(&s, "a.b.tracker.test"))
	testing.expect(t, !enabled_for(&s, "TRACKER.test"))
	testing.expect(t, enabled_for(&s, "example.com"))
	s.enabled = false
	delete(s.sites_enabled)
	s.sites_enabled = split_sites("example.com")
	testing.expect(t, enabled_for(&s, "example.com"))
	testing.expect(t, !enabled_for(&s, "other.org"))
	testing.expect(t, !enabled_for(&s, ""))
}

@(test)
time_zone :: proc(t: ^testing.T) {
	// whatever the machine's zone: an offset in minutes within the world's range, stable for one instant
	o := timezone_offset(0)
	testing.expect(t, o >= -14 * 60 && o <= 12 * 60)
	testing.expect_value(t, timezone_offset(1.7e12), timezone_offset(1.7e12))
	testing.expect_value(t, timezone_offset(math.nan_f64()), 0)
}
