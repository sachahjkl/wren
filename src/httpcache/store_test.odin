package httpcache

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:host"
import "wb:http"

@(private = "file")
test_settings :: proc() -> Settings {
	s := settings_default()
	s.index_flush_ms = 0
	return s
}

@(private = "file")
temp_dir :: proc(name: string) -> string {
	dir := fmt.tprintf("build/httpcache_test_%s_%d", name, time.to_unix_nanoseconds(time.now()))
	_ = os.make_directory_all(dir)
	return dir
}

@(private = "file")
wipe :: proc(dir: string) {
	for f in list_dir(dir) { delete_file(strings.concatenate({dir, SEP, f.name}, context.temp_allocator)) }
	_ = os.remove(dir)   // (empty now)
}

@(private = "file")
pump_until :: proc(l: ^host.Loop, cond: proc(data: rawptr) -> bool, data: rawptr, ms := 5000) -> bool {
	start := time.tick_now()
	for !cond(data) {
		if time.duration_milliseconds(time.tick_since(start)) > f64(ms) { return false }
		host.loop_wait(l, 10)
	}
	return true
}

@(private = "file")
put :: proc(c: ^Cache, key, block: string, body: string) -> ^Entry {
	h := http.parse_header_block(block, context.temp_allocator)
	return store(c, Store_Desc{key = key, url = key, status = 200, headers = h, body = transmute([]byte)body, request_time = now_s(), response_time = now_s(), fresh_until = now_s() + 60})
}

@(test)
test_memory_store_and_lru :: proc(t: ^testing.T) {
	l: host.Loop
	host.loop_init(&l)
	defer host.loop_destroy(&l)
	s := test_settings()
	defer settings_destroy(&s)
	s.memory_max_bytes = 10
	c := create(&l, s, "")
	defer destroy(c)
	testing.expect(t, is_ready(c))
	put(c, "a", "Cache-Control: max-age=60\r\nSet-Cookie: x=y\r\nConnection: close\r\n", "aaaa")
	put(c, "b", "Cache-Control: max-age=60\r\n", "bbbb")
	e := find(c, "a")
	testing.expect(t, e != nil && e.resident && string(e.body.data) == "aaaa")
	// stored without cookies and hop-by-hop fields, with a Date
	testing.expect(t, !strings.contains(e.meta.headers, "Set-Cookie") && !strings.contains(e.meta.headers, "Connection"))
	testing.expect(t, strings.contains(e.meta.headers, "Date: "))
	touch(c, e)   // b is now the least recently used
	put(c, "c", "Cache-Control: max-age=60\r\n", "cccc")
	testing.expect(t, find(c, "b") == nil)
	testing.expect(t, find(c, "a") != nil && find(c, "c") != nil)
	testing.expect_value(t, c.resident_bytes, 8)
	// too large for an entry
	s2 := c.settings
	s2.max_entry_bytes = 3
	apply_settings(c, s2)
	testing.expect(t, put(c, "d", "", "dddd") == nil)
	// invalidation by URL, clear
	testing.expect_value(t, invalidate_url(c, "a"), 1)
	clear_all(c)
	testing.expect_value(t, len(c.entries), 0)
}

@(test)
test_refresh_304 :: proc(t: ^testing.T) {
	l: host.Loop
	host.loop_init(&l)
	defer host.loop_destroy(&l)
	s := test_settings()
	defer settings_destroy(&s)
	c := create(&l, s, "")
	defer destroy(c)
	e := put(c, "k", "ETag: \"1\"\r\nCache-Control: max-age=1\r\nContent-Type: text/plain\r\n", "body")
	fresh := http.parse_header_block("ETag: \"1\"\r\nCache-Control: max-age=100\r\nContent-Type: text/html\r\n", context.temp_allocator)
	refresh(c, e, fresh, 5, 6, 106)
	h := headers_of(e)
	v, _ := http.get_header(h, "cache-control")
	testing.expect_value(t, v, "max-age=100")
	v, _ = http.get_header(h, "content-type")
	testing.expect_value(t, v, "text/plain")
	testing.expect(t, e.meta.response_time == 6 && string(e.body.data) == "body" && c.stats.revalidated == 1)
}

@(private = "file")
is_ready_proc :: proc(data: rawptr) -> bool { return (^Cache)(data).ready }

@(private = "file")
Load_State :: struct { done, ok: bool }

@(private = "file")
writes_done :: proc(data: rawptr) -> bool {
	c := (^Cache)(data)
	for _, e in c.entries { if e.disk == .Writing { return false } }
	return true
}

@(private = "file")
reopen :: proc(l: ^host.Loop, c: ^Cache, s: Settings, dir: string) -> ^Cache {
	destroy(c)
	n := create(l, s, dir)
	pump_until(l, is_ready_proc, n)
	return n
}

@(private = "file")
load_sync :: proc(t: ^testing.T, l: ^host.Loop, c: ^Cache, key: string) -> bool {
	e := find(c, key)
	if e == nil { return false }
	st: Load_State
	_, pending := load(c, e, proc(user: rawptr, ok: bool) { s := (^Load_State)(user); s.done, s.ok = true, ok }, &st)
	if !pending { return true }
	testing.expect(t, pump_until(l, proc(d: rawptr) -> bool { return (^Load_State)(d).done }, &st))
	return st.ok
}

@(test)
test_disk_round_trip :: proc(t: ^testing.T) {
	l: host.Loop
	host.loop_init(&l)
	defer host.loop_destroy(&l)
	dir := temp_dir("roundtrip")
	defer wipe(dir)
	s := test_settings()
	defer settings_destroy(&s)
	c := create(&l, s, dir)
	testing.expect(t, pump_until(&l, is_ready_proc, c))
	put(c, "one", "Cache-Control: max-age=60\r\nContent-Type: text/css\r\n", "body one")
	put(c, "two", "Cache-Control: max-age=60\r\n", strings.repeat("x", 100_000, context.temp_allocator))
	testing.expect(t, pump_until(&l, writes_done, c))
	// a new start: the index has both, not resident; reading gives the response back
	destroy(c)
	testing.expect(t, os.exists(strings.concatenate({dir, SEP, INDEX_NAME}, context.temp_allocator)))
	c = create(&l, s, dir)
	testing.expect(t, pump_until(&l, is_ready_proc, c))
	testing.expect_value(t, len(c.entries), 2)
	e := find(c, "one")
	testing.expect(t, e != nil && !e.resident && e.disk == .Stored)
	testing.expect(t, load_sync(t, &l, c, "one"))
	e = find(c, "one")
	testing.expect(t, e.resident && string(e.body.data) == "body one" && strings.contains(e.meta.headers, "text/css"))
	testing.expect(t, load_sync(t, &l, c, "two"))
	testing.expect_value(t, len(find(c, "two").body.data), 100_000)
	// the index lost (a crash before it was written): rebuilt from the files
	destroy(c)
	delete_file(strings.concatenate({dir, SEP, INDEX_NAME}, context.temp_allocator))
	c = create(&l, s, dir)
	testing.expect(t, pump_until(&l, is_ready_proc, c))
	testing.expect_value(t, len(c.entries), 2)
	testing.expect(t, load_sync(t, &l, c, "one"))
	destroy(c)
}

@(test)
test_disk_damage :: proc(t: ^testing.T) {
	l: host.Loop
	host.loop_init(&l)
	defer host.loop_destroy(&l)
	dir := temp_dir("damage")
	defer wipe(dir)
	s := test_settings()
	defer settings_destroy(&s)
	c := create(&l, s, dir)
	testing.expect(t, pump_until(&l, is_ready_proc, c))
	put(c, "trunc", "Cache-Control: max-age=60\r\n", "0123456789abcdef")
	put(c, "flip", "Cache-Control: max-age=60\r\n", "0123456789abcdef")
	put(c, "good", "Cache-Control: max-age=60\r\n", "0123456789abcdef")
	testing.expect(t, pump_until(&l, writes_done, c))
	trunc := entry_path(c.disk, find(c, "trunc").serial, "wce", context.allocator)
	flip := entry_path(c.disk, find(c, "flip").serial, "wce", context.allocator)
	defer { delete(trunc); delete(flip) }
	destroy(c)
	// truncate one file, damage a byte of another's body, leave a temporary file behind, damage the index
	if b, ok := read_file(trunc); ok { write_file(trunc, {b[:len(b) - 3]}, false); delete(b, heap()) }
	if b, ok := read_file(flip); ok { b[len(b) - 1] ~= 0xFF; write_file(flip, {b}, false); delete(b, heap()) }
	write_file(strings.concatenate({dir, "\\00000000000000ff.tmp"}, context.temp_allocator), {transmute([]byte)string("half")}, false)
	idx := strings.concatenate({dir, SEP, INDEX_NAME}, context.temp_allocator)
	if b, ok := read_file(idx); ok { b[10] ~= 0xFF; write_file(idx, {b}, false); delete(b, heap()) }
	c = create(&l, s, dir)
	testing.expect(t, pump_until(&l, is_ready_proc, c))
	// the truncated file does not match its size: dropped at start-up (rebuilt index); the damaged body when read
	testing.expect(t, find(c, "trunc") == nil)
	testing.expect(t, find(c, "flip") != nil)
	testing.expect(t, !load_sync(t, &l, c, "flip"))
	testing.expect(t, find(c, "flip") == nil)
	testing.expect_value(t, c.stats.disk_failures, 1)
	testing.expect(t, load_sync(t, &l, c, "good"))
	for f in list_dir(dir) { testing.expect(t, !strings.has_suffix(f.name, ".tmp")) }
	destroy(c)
}

@(test)
test_disk_eviction :: proc(t: ^testing.T) {
	l: host.Loop
	host.loop_init(&l)
	defer host.loop_destroy(&l)
	dir := temp_dir("evict")
	defer wipe(dir)
	s := test_settings()
	defer settings_destroy(&s)
	s.disk_max_bytes = 3000
	s.memory_max_bytes = 1500
	c := create(&l, s, dir)
	defer destroy(c)
	testing.expect(t, pump_until(&l, is_ready_proc, c))
	for i in 0 ..< 10 {
		put(c, fmt.tprintf("k%d", i), "Cache-Control: max-age=60\r\n", strings.repeat("z", 500, context.temp_allocator))
		pump_until(&l, writes_done, c)
	}
	testing.expect(t, c.disk_bytes <= 3000)
	testing.expect(t, c.resident_bytes <= 1500)
	testing.expect(t, find(c, "k9") != nil && find(c, "k0") == nil)
	testing.expect(t, c.stats.evicted > 0)
	// files of evicted entries are deleted
	pump_until(&l, proc(d: rawptr) -> bool { return true }, nil)
	time.sleep(50 * time.Millisecond)
	n := 0
	for f in list_dir(dir) { if strings.has_suffix(f.name, ".wce") { n += 1 } }
	testing.expect_value(t, n, len(c.entries))
}
