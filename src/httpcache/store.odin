package httpcache

import "core:strings"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:http"

// The entries of the cache, on the loop (UI) thread.
//
//   * Every entry is known by its key (partition + URL, made by package fetch) and listed from most to least recently
//     used. That order decides what goes when the cache is over its size.
//   * An entry is *resident* when its stored response (metadata and body) is in memory. Resident bodies are bounded by
//     network.cache.memory.max_bytes, least recently used first out. With a disk, an entry that is not resident is a
//     few numbers (file, size, last use, freshness hint) and is read back (one file, metadata and body) when a request
//     wants it: everything is judged on resident entries. Without a disk, an entry that stops being resident is gone.
//   * Bodies are shared, counted buffers: a body being written to disk, delivered to a request and kept in memory is
//     one allocation.
//   * Waiting for the disk (the index while it loads, an entry being read) is a ticket: the requester may cancel it, and
//     its callback is then never called.

Body :: struct {
	refs: i32,      // atomic
	data: []byte,   // heap
}

body_make :: proc(data: []byte) -> ^Body {
	b := new(Body, base.process_allocator())
	b.refs = 1
	b.data = data
	return b
}

body_retain :: proc(b: ^Body) -> ^Body {
	if b != nil { sync.atomic_add(&b.refs, 1) }
	return b
}

body_release :: proc(b: ^Body) {
	if b == nil { return }
	if sync.atomic_sub(&b.refs, 1) == 1 {
		delete(b.data, base.process_allocator())
		free(b, base.process_allocator())
	}
}

// A stored response as it is kept and written (heap strings).
Meta :: struct {
	key:           string,
	url:           string,
	status:        int,
	headers:       string,   // the stored response's fields, "Name: value\r\n" each
	vary:          string,   // the request's values of the fields the response varies on, same form (absent = not listed)
	request_time:  i64,      // unix s
	response_time: i64,      // unix s
	stored_ms:     i64,      // when this response was stored (unix ms; about:cache)
}

meta_destroy :: proc(m: ^Meta) {
	a := base.process_allocator()
	delete(m.key, a); delete(m.url, a); delete(m.headers, a); delete(m.vary, a)
	m^ = {}
}

meta_clone :: proc(m: Meta) -> Meta {
	a := base.process_allocator()
	r := m
	r.key = strings.clone(m.key, a)
	r.url = strings.clone(m.url, a)
	r.headers = strings.clone(m.headers, a)
	r.vary = strings.clone(m.vary, a)
	return r
}

Disk_State :: enum u8 {
	None,      // memory only
	Writing,   // a write is queued or running: the entry stays resident until it is on disk
	Stored,
}

Entry :: struct {
	key:          string,   // heap
	url:          string,   // heap
	status:       int,
	body_size:    i64,
	file_size:    i64,      // on disk (0 = not on disk)
	serial:       u64,      // its file (0 = none)
	disk:         Disk_State,
	last_used_ms: i64,
	fresh_until:  i64,      // unix s: until when it was fresh when last judged (a hint: about:cache, cache_hint)
	hits:         int,
	// resident
	resident:     bool,
	meta:         Meta,
	body:         ^Body,
	loading:      bool,     // a read from disk is under way
	// lists
	prev, next:   ^Entry,   // every entry, most recently used first
	rprev, rnext: ^Entry,   // resident entries, most recently used first
}

Stats :: struct {
	hits:          int,   // served without the network
	revalidated:   int,   // 304: served after asking
	misses:        int,
	stored:        int,
	evicted:       int,
	disk_reads:    int,
	disk_failures: int,   // unreadable, truncated or corrupt files (dropped)
	bytes_served:  i64,
}

Ticket :: u64

Wait_Proc :: #type proc(user: rawptr, ok: bool)

@(private)
Waiter :: struct {
	ticket: Ticket,
	key:    string,   // "" = waiting for the index
	fn:     Wait_Proc,
	user:   rawptr,
}

Cache :: struct {
	loop:           ^host.Loop,
	settings:       Settings,
	entries:        map[string]^Entry,
	head, tail:     ^Entry,
	rhead, rtail:   ^Entry,
	resident_bytes: i64,
	disk_bytes:     i64,
	stats:          Stats,
	ready:          bool,            // the index is loaded (always, without a disk)
	waiters:        [dynamic]Waiter,
	next_ticket:    Ticket,
	disk:           ^Disk,            // nil: memory only
	index_dirty:    bool,
	flush_timer:    base.Handle,     // the index is written when it fires
	destroyed:      bool,
}

// `dir` "" (or disk caching off): memory only. With a directory, the index is read on a thread of the cache; requests
// that come meanwhile wait for it (when_ready).
create :: proc(loop: ^host.Loop, settings: Settings, dir: string) -> ^Cache {
	c := new(Cache)
	c.loop = loop
	c.settings = settings_clone(settings)
	c.entries = make(map[string]^Entry)
	c.waiters = make([dynamic]Waiter)
	if dir != "" && settings.disk_enabled {
		c.disk = disk_open(c, dir)
	}
	if c.disk == nil { c.ready = true }
	return c
}

// Writes what is pending and the index, stops the threads, frees everything. Waiters are dropped without a call.
destroy :: proc(c: ^Cache) {
	if c == nil { return }
	c.destroyed = true
	if c.flush_timer != base.NIL_HANDLE { host.clear_timer(c.loop, c.flush_timer); c.flush_timer = base.NIL_HANDLE }
	if c.disk != nil {
		if c.ready { disk_save_index(c) }
		disk_close(c)
		c.disk = nil
	}
	for e := c.head; e != nil; {
		n := e.next
		entry_free(e)
		e = n
	}
	delete(c.entries)
	for w in c.waiters { delete(w.key) }
	delete(c.waiters)
	settings_destroy(&c.settings)
	free(c)
}

// New preferences: sizes take effect at once (trimming), the directory and the disk switch at the next start.
apply_settings :: proc(c: ^Cache, s: Settings) {
	dir := strings.clone(c.settings.directory)
	disk := c.settings.disk_enabled
	settings_destroy(&c.settings)
	c.settings = settings_clone(s)
	delete(c.settings.directory)
	c.settings.directory = dir
	c.settings.disk_enabled = disk
	trim(c)
}

is_ready :: proc(c: ^Cache) -> bool { return c.ready }

// Calls `fn(user, true)` from the loop once the index is loaded. Cancel with `cancel`.
when_ready :: proc(c: ^Cache, fn: Wait_Proc, user: rawptr) -> Ticket {
	c.next_ticket += 1
	append(&c.waiters, Waiter{ticket = c.next_ticket, fn = fn, user = user})
	return c.next_ticket
}

// The callback of `t` will not be called.
cancel :: proc(c: ^Cache, t: Ticket) {
	if c == nil || t == 0 { return }
	for w, i in c.waiters {
		if w.ticket == t { delete(w.key); ordered_remove(&c.waiters, i); return }
	}
}

find :: proc(c: ^Cache, key: string) -> ^Entry {
	return c.entries[key] or_else nil
}

now_s :: proc() -> i64 { return time.to_unix_seconds(time.now()) }
now_ms :: proc() -> i64 { return time.to_unix_nanoseconds(time.now()) / 1_000_000 }

// Makes `e` resident. Already resident: false (nothing to wait for). Else `fn(user, ok)` is called from the loop when
// it is read (ok false: the file was gone or damaged, and the entry with it). Cancel with `cancel`.
load :: proc(c: ^Cache, e: ^Entry, fn: Wait_Proc, user: rawptr) -> (ticket: Ticket, pending: bool) {
	if e.resident { return 0, false }
	c.next_ticket += 1
	append(&c.waiters, Waiter{ticket = c.next_ticket, key = strings.clone(e.key), fn = fn, user = user})
	if !e.loading && c.disk != nil && e.disk == .Stored {
		e.loading = true
		c.stats.disk_reads += 1
		disk_read(c, e.key, e.serial)
	} else if !e.loading {
		// nothing to read it from (cannot happen: a non-resident entry is on disk); answer "gone" from the loop
		k := strings.clone(e.key)
		remove(c, e)
		post_load_failed(c, k)
	}
	return c.next_ticket, true
}

// The stored response's fields, parsed (temp allocator).
headers_of :: proc(e: ^Entry, allocator := context.temp_allocator) -> http.Headers {
	return http.parse_header_block(e.meta.headers, allocator)
}

// Marks `e` used now (LRU order, about:cache).
touch :: proc(c: ^Cache, e: ^Entry) {
	e.last_used_ms = now_ms()
	e.hits += 1
	list_unlink(c, e)
	list_push_front(c, e)
	if e.resident { rlist_unlink(c, e); rlist_push_front(c, e) }
	if e.disk == .Stored { mark_index_dirty(c) }
}

Store_Desc :: struct {
	key, url:      string,
	status:        int,
	headers:       http.Headers,   // as received; sanitized here
	vary:          string,         // request values of the varied fields (Vary block)
	request_time:  i64,
	response_time: i64,
	body:          []byte,         // copied
	fresh_until:   i64,
}

// Stores a response, replacing any entry of the same key. Nil when it is larger than an entry may be.
store :: proc(c: ^Cache, d: Store_Desc) -> ^Entry {
	if i64(len(d.body)) > c.settings.max_entry_bytes { return nil }
	if old := find(c, d.key); old != nil { remove(c, old) }
	a := base.process_allocator()
	data := make([]byte, len(d.body), a)
	copy(data, d.body)
	e := new(Entry)
	e.key = strings.clone(d.key, a)
	e.url = strings.clone(d.url, a)
	e.status = d.status
	e.body_size = i64(len(d.body))
	e.last_used_ms = now_ms()
	e.fresh_until = d.fresh_until
	e.meta = Meta{
		key = strings.clone(d.key, a), url = strings.clone(d.url, a), status = d.status,
		headers = stored_header_block(d.headers, len(d.body), d.response_time), vary = strings.clone(d.vary, a),
		request_time = d.request_time, response_time = d.response_time, stored_ms = e.last_used_ms,
	}
	e.body = body_make(data)
	e.resident = true
	c.entries[e.key] = e
	list_push_front(c, e)
	rlist_push_front(c, e)
	c.resident_bytes += e.body_size
	c.stats.stored += 1
	if c.disk != nil && c.ready { disk_write(c, e) }
	trim(c)
	return find(c, d.key)   // (trimming may have taken it at once when the cache is tiny)
}

// RFC 9111 §4.3.4: a 304 refreshed the resident entry `e`.
refresh :: proc(c: ^Cache, e: ^Entry, fresh: http.Headers, request_time, response_time: i64, fresh_until: i64) {
	stored := headers_of(e)
	merged := merge_304(stored, fresh, context.temp_allocator)
	a := base.process_allocator()
	delete(e.meta.headers, a)
	e.meta.headers = stored_header_block(merged, int(e.body_size), response_time)
	e.meta.request_time, e.meta.response_time = request_time, response_time
	e.fresh_until = fresh_until
	c.stats.revalidated += 1
	if c.disk != nil && c.ready && e.disk != .None { disk_write(c, e) }
	touch(c, e)
}

// The fields a stored response keeps, as a block: no hop-by-hop fields, no cookies; the body is stored decoded (the
// transport decompresses), so its coding and length are those of the stored bytes; a Date is added when the server
// sent none.
@(private)
stored_header_block :: proc(h: http.Headers, body_len: int, response_time: i64) -> string {
	sb := strings.builder_make(base.process_allocator())
	encoded := http.has_header(h, "content-encoding")
	for e in h.list {
		if is_hop_by_hop(e.name) || is_never_stored(e.name) { continue }
		if encoded && (strings.equal_fold(e.name, "content-encoding") || strings.equal_fold(e.name, "content-length")) { continue }
		strings.write_string(&sb, e.name)
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, e.value)
		strings.write_string(&sb, "\r\n")
	}
	if encoded {
		strings.write_string(&sb, "Content-Length: ")
		strings.write_int(&sb, body_len)
		strings.write_string(&sb, "\r\n")
	}
	if !http.has_header(h, "date") {
		strings.write_string(&sb, "Date: ")
		strings.write_string(&sb, format_http_date(response_time, context.temp_allocator))
		strings.write_string(&sb, "\r\n")
	}
	return strings.to_string(sb)
}

// Removes `e` (its file too).
remove :: proc(c: ^Cache, e: ^Entry) {
	if e == nil { return }
	if cur := find(c, e.key); cur != e { return }
	delete_key(&c.entries, e.key)
	list_unlink(c, e)
	if e.resident { rlist_unlink(c, e); c.resident_bytes -= e.body_size }
	if e.serial != 0 && c.disk != nil {
		c.disk_bytes -= e.file_size
		disk_delete(c, e.serial)
		mark_index_dirty(c)
	}
	entry_free(e)
}

remove_key :: proc(c: ^Cache, key: string) { remove(c, find(c, key)) }

// RFC 9111 §4.4: an unsafe request succeeded: every stored response for `url` (in every partition) goes.
invalidate_url :: proc(c: ^Cache, url: string) -> int {
	doomed := make([dynamic]^Entry, context.temp_allocator)
	for _, e in c.entries { if e.url == url { append(&doomed, e) } }
	for e in doomed { remove(c, e) }
	return len(doomed)
}

// Everything goes (memory and disk). Requests waiting for an entry are told it is gone.
clear_all :: proc(c: ^Cache) {
	keys := make([dynamic]string, context.temp_allocator)
	for k in c.entries { append(&keys, strings.clone(k, context.temp_allocator)) }
	for k in keys { remove_key(c, k) }
	if c.disk != nil { disk_clear(c) }
	c.stats = {}
	fail_waiters_for_missing(c)
}

// Count and bytes, for about:cache.
Summary :: struct {
	entries:        int,
	resident:       int,
	resident_bytes: i64,
	disk_entries:   int,
	disk_bytes:     i64,
	stats:          Stats,
	directory:      string,
	ready:          bool,
}

summary :: proc(c: ^Cache) -> Summary {
	s := Summary{entries = len(c.entries), resident_bytes = c.resident_bytes, disk_bytes = c.disk_bytes, stats = c.stats, ready = c.ready}
	for e := c.rhead; e != nil; e = e.rnext { s.resident += 1 }
	for _, e in c.entries { if e.disk == .Stored { s.disk_entries += 1 } }
	if c.disk != nil { s.directory = c.disk.dir }
	return s
}

// Entries, most recently used first.
first :: proc(c: ^Cache) -> ^Entry { return c.head }

////////////////////////////////
// Size

// Bounds: resident bodies within memory.max_bytes, the disk within disk.max_bytes, the count within max_entries.
@(private)
trim :: proc(c: ^Cache) {
	s := &c.settings
	// resident bodies: least recently used first; entries still being written stay (their write holds the body anyway)
	for e := c.rtail; e != nil && c.resident_bytes > s.memory_max_bytes; {
		p := e.rprev
		switch e.disk {
		case .Stored:
			make_non_resident(c, e)
		case .None:
			c.stats.evicted += 1
			remove(c, e)
		case .Writing:
		}
		e = p
	}
	limit := c.disk != nil ? s.disk_max_bytes : s.memory_max_bytes
	for e := c.tail; e != nil && (c.disk_bytes > limit || len(c.entries) > s.max_entries); {
		p := e.prev
		if e.disk != .Writing || len(c.entries) > s.max_entries {
			c.stats.evicted += 1
			remove(c, e)
		}
		e = p
	}
}

@(private)
make_non_resident :: proc(c: ^Cache, e: ^Entry) {
	if !e.resident { return }
	rlist_unlink(c, e)
	c.resident_bytes -= e.body_size
	e.resident = false
	body_release(e.body)
	e.body = nil
	meta_destroy(&e.meta)
}

@(private)
entry_free :: proc(e: ^Entry) {
	a := base.process_allocator()
	body_release(e.body)
	meta_destroy(&e.meta)
	delete(e.key, a)
	delete(e.url, a)
	free(e)
}

@(private)
mark_index_dirty :: proc(c: ^Cache) {
	c.index_dirty = true
	if c.disk == nil || c.flush_timer != base.NIL_HANDLE || c.destroyed || c.settings.index_flush_ms <= 0 { return }
	c.flush_timer = host.set_timer(c.loop, f64(c.settings.index_flush_ms), 0, proc(data: rawptr) {
		c := (^Cache)(data)
		c.flush_timer = base.NIL_HANDLE
		if c.index_dirty && c.ready && c.disk != nil { disk_save_index(c) }
	}, c)
}

////////////////////////////////
// Waiters

@(private)
run_waiters :: proc(c: ^Cache, key: string, ok: bool) {
	// callbacks may add or cancel waiters: take the matching ones out first
	ready := make([dynamic]Waiter, context.temp_allocator)
	for i := 0; i < len(c.waiters); {
		w := c.waiters[i]
		if w.key == key { append(&ready, w); ordered_remove(&c.waiters, i) } else { i += 1 }
	}
	for w in ready {
		delete(w.key)
		w.fn(w.user, ok)
	}
}

// After a clear: whoever waited for an entry that no longer exists hears so.
@(private)
fail_waiters_for_missing :: proc(c: ^Cache) {
	keys := make([dynamic]string, context.temp_allocator)
	for w in c.waiters { if w.key != "" && find(c, w.key) == nil { append(&keys, strings.clone(w.key, context.temp_allocator)) } }
	for k in keys { run_waiters(c, k, false) }
}

@(private)
Failed_Load :: struct { c: ^Cache, key: string }

@(private)
post_load_failed :: proc(c: ^Cache, key: string) {
	host.post(c.loop, proc(data: rawptr) {
		f := (^Failed_Load)(data)
		if !f.c.destroyed { run_waiters(f.c, f.key, false) }
		delete(f.key)
		free(f)
	}, new_clone(Failed_Load{c, key}))
}

////////////////////////////////
// Lists

@(private)
list_push_front :: proc(c: ^Cache, e: ^Entry) {
	e.prev, e.next = nil, c.head
	if c.head != nil { c.head.prev = e } else { c.tail = e }
	c.head = e
}

@(private)
list_unlink :: proc(c: ^Cache, e: ^Entry) {
	if e.prev != nil { e.prev.next = e.next } else { c.head = e.next }
	if e.next != nil { e.next.prev = e.prev } else { c.tail = e.prev }
	e.prev, e.next = nil, nil
}

// Appends at the least recently used end (entries read from the index, oldest last).
@(private)
list_push_back :: proc(c: ^Cache, e: ^Entry) {
	e.next, e.prev = nil, c.tail
	if c.tail != nil { c.tail.next = e } else { c.head = e }
	c.tail = e
}

@(private)
rlist_push_front :: proc(c: ^Cache, e: ^Entry) {
	e.rprev, e.rnext = nil, c.rhead
	if c.rhead != nil { c.rhead.rprev = e } else { c.rtail = e }
	c.rhead = e
}

@(private)
rlist_unlink :: proc(c: ^Cache, e: ^Entry) {
	if e.rprev != nil { e.rprev.rnext = e.rnext } else { c.rhead = e.rnext }
	if e.rnext != nil { e.rnext.rprev = e.rprev } else { c.rtail = e.rprev }
	e.rprev, e.rnext = nil, nil
}

////////////////////////////////
// Dates

@(private)
DAY_NAMES := [7]string{"Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"}   // 1970-01-01 was a Thursday
@(private)
MONTH_NAMES := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT") of unix seconds.
format_http_date :: proc(t: i64, allocator := context.temp_allocator) -> string {
	days := t / 86400
	rem := t % 86400
	if rem < 0 { rem += 86400; days -= 1 }
	wd := ((days % 7) + 7) % 7
	// civil from days (Howard Hinnant)
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp < 10 ? mp + 3 : mp - 9
	if m <= 2 { y += 1 }
	sb := strings.builder_make(allocator)
	two :: proc(sb: ^strings.Builder, v: i64) { if v < 10 { strings.write_byte(sb, '0') }; strings.write_i64(sb, v) }
	strings.write_string(&sb, DAY_NAMES[wd])
	strings.write_string(&sb, ", ")
	two(&sb, d)
	strings.write_byte(&sb, ' ')
	strings.write_string(&sb, MONTH_NAMES[m - 1])
	strings.write_byte(&sb, ' ')
	strings.write_i64(&sb, y)
	strings.write_byte(&sb, ' ')
	two(&sb, rem / 3600)
	strings.write_byte(&sb, ':')
	two(&sb, (rem % 3600) / 60)
	strings.write_byte(&sb, ':')
	two(&sb, rem % 60)
	strings.write_string(&sb, " GMT")
	return strings.to_string(sb)
}

////////////////////////////////
// By site (about:sites, "Clear site data")

// The host of an absolute URL or site ("https://a.example:8443/x" -> "a.example").
host_of_url :: proc(u: string) -> string {
	s := u
	if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] }
	if i := strings.index_any(s, "/?#"); i >= 0 { s = s[:i] }
	if i := strings.last_index_byte(s, '@'); i >= 0 { s = s[i + 1:] }
	if strings.has_prefix(s, "[") {
		if j := strings.index_byte(s, ']'); j >= 0 { return s[:j + 1] }
	}
	if i := strings.index_byte(s, ':'); i >= 0 { s = s[:i] }
	return s
}

// Whether the entry belongs to `host`: its URL is there, or it is kept for a page of that top-level site (the key is
// "1/<top-level site> <frame site> <credentials> <url>").
entry_of_host :: proc(e: ^Entry, host: string) -> bool {
	if host_of_url(e.url) == host { return true }
	if strings.has_prefix(e.key, "1/") {
		rest := e.key[2:]
		if i := strings.index_byte(rest, ' '); i >= 0 { return host_of_url(rest[:i]) == host }
	}
	return false
}

// The entries and bytes the cache keeps for each host (temporary map; a host is counted for the URL's and the top-level site's).
bytes_by_host :: proc(c: ^Cache, allocator := context.temp_allocator) -> map[string]i64 {
	out := make(map[string]i64, allocator = allocator)
	for e := c.head; e != nil; e = e.next {
		n := e.file_size if e.file_size > 0 else e.body_size
		h := host_of_url(e.url)
		out[strings.clone(h, allocator)] += n
		if strings.has_prefix(e.key, "1/") {
			rest := e.key[2:]
			if i := strings.index_byte(rest, ' '); i >= 0 {
				if th := host_of_url(rest[:i]); th != h { out[strings.clone(th, allocator)] += n }
			}
		}
	}
	return out
}

// Removes the entries of a host; returns how many.
delete_for_host :: proc(c: ^Cache, host: string) -> int {
	keys := make([dynamic]string, context.temp_allocator)
	for e := c.head; e != nil; e = e.next {
		if entry_of_host(e, host) { append(&keys, strings.clone(e.key, context.temp_allocator)) }
	}
	for k in keys { remove_key(c, k) }
	return len(keys)
}