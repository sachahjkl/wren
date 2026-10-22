package httpcache

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "wb:host"
import "wb:base"

// The cache on disk, in the profile (network.cache.disk.directory, else <profile>/cache):
//
//   <serial>.wce   one stored response: a fixed header (magic, format version, lengths, CRC-32 of the metadata and of
//                  the body), the metadata (key, URL, status, fields, Vary values, times), the body.
//   index.wci      what the cache knows at start-up without reading every file: per entry its key, URL, file, sizes,
//                  last use and freshness hint; a CRC-32 over the whole file.
//
// Robustness: every file is written under a temporary name and renamed over its final one (a reader sees the old file
// or the new one, never half of one). A response is never trusted without its checksums: a file that is missing,
// truncated, of another format version or damaged is dropped (and deleted) when it is read, and the request goes to the
// network. The index is a snapshot written now and then (network.cache.disk.index_flush_ms) and when the browser
// closes; at start-up it is checked against the directory: entries whose file is gone are dropped, files the index does
// not know (written after the last snapshot, before a crash) are taken back from their own metadata, anything else of
// ours (temporary files, other versions) is deleted. A damaged index is rebuilt from the files.
//
// Threads: one writer runs writes, deletions, index snapshots and clearing in order; network.cache.disk.read_threads
// readers read entries. Neither touches the cache: results come back to the loop through one queue and one post.

FORMAT_VERSION :: u32(1)
@(private) ENTRY_MAGIC :: u32(0x434E5257)   // "WRNC"
@(private) INDEX_MAGIC :: u32(0x494E5257)   // "WRNI"
@(private) ENTRY_HEADER :: 32
@(private) INDEX_NAME :: "index.wci"

@(private)
Op_Kind :: enum u8 { Load_Index, Write, Delete, Save_Index, Clear, Read }

@(private)
Index_Record :: struct {
	serial:      u64,
	file_size:   i64,
	body_size:   i64,
	last_used:   i64,
	fresh_until: i64,
	status:      int,
	key, url:    string,   // heap
}

@(private)
Op :: struct {
	kind:      Op_Kind,
	serial:    u64,
	old:       u64,              // write: the file it replaces (deleted once the new one is there)
	key:       string,           // read: heap
	head:      []byte,           // write: header + metadata; save index: the whole file (heap)
	body:      ^Body,            // write
	// results
	ok:        bool,
	meta:      Meta,             // read
	read_body: ^Body,            // read
	records:   [dynamic]Index_Record,   // load
	next_serial: u64,            // load
	changed:   bool,             // load: the index did not match the directory
}

Disk :: struct {
	cache:         ^Cache,
	loop:          ^host.Loop,
	dir:           string,
	mu:            sync.Mutex,
	cond:          sync.Cond,
	wq, rq:        [dynamic]^Op,
	stopping:      bool,
	writer:        ^host.Thread,
	readers:       [dynamic]^host.Thread,
	cmu:           sync.Mutex,
	done:          [dynamic]^Op,
	drain_pending: bool,
	next_serial:   u64,          // loop thread
}

// Disks alive: a drain posted to the loop just before its disk closed finds it gone and does nothing.
@(private) live_mu: sync.Mutex
@(private) live: map[rawptr]bool

@(private)
heap :: proc() -> runtime.Allocator { return base.process_allocator() }

@(private)
disk_open :: proc(c: ^Cache, dir: string) -> ^Disk {
	a := heap()
	d := new(Disk, a)
	d.cache, d.loop = c, c.loop
	d.dir = strings.clone(strings.trim_right(dir, "\\/"), a)
	d.wq = make([dynamic]^Op, a)
	d.rq = make([dynamic]^Op, a)
	d.done = make([dynamic]^Op, a)
	d.readers = make([dynamic]^host.Thread, a)
	d.next_serial = 1
	make_dirs(d.dir)
	sync.mutex_lock(&live_mu)
	if live == nil { live = make(map[rawptr]bool, a) }
	live[d] = true
	sync.mutex_unlock(&live_mu)
	op := new(Op, a)
	op.kind = .Load_Index
	push_write(d, op)
	d.writer = host.thread_start(writer_main, d, priority = .Below_Normal, name = "wren-httpcache-writer")
	for _ in 0 ..< max(c.settings.read_threads, 1) {
		if t := host.thread_start(reader_main, d, priority = .Below_Normal, name = "wren-httpcache-reader"); t != nil { append(&d.readers, t) }
	}
	if d.writer == nil || len(d.readers) == 0 { disk_close_raw(d); return nil }
	return d
}

// Lets the writer finish its queue (writes, the last index), stops every thread, frees what never came back.
@(private)
disk_close :: proc(c: ^Cache) { disk_close_raw(c.disk) }

@(private)
disk_close_raw :: proc(d: ^Disk) {
	if d == nil { return }
	sync.mutex_lock(&live_mu)
	delete_key(&live, d)
	if len(live) == 0 { delete(live); live = nil }
	sync.mutex_unlock(&live_mu)
	sync.mutex_lock(&d.mu)
	d.stopping = true
	sync.cond_broadcast(&d.cond)
	sync.mutex_unlock(&d.mu)
	if d.writer != nil { host.thread_join(d.writer) }
	for t in d.readers { host.thread_join(t) }
	for op in d.wq { op_free(op) }
	for op in d.rq { op_free(op) }
	for op in d.done { op_free(op) }
	a := heap()
	delete(d.wq); delete(d.rq); delete(d.done); delete(d.readers)
	delete(d.dir, a)
	free(d, a)
}

@(private)
op_free :: proc(op: ^Op) {
	a := heap()
	delete(op.key, a)
	delete(op.head, a)
	body_release(op.body)
	body_release(op.read_body)
	meta_destroy(&op.meta)
	for &r in op.records { delete(r.key, a); delete(r.url, a) }
	delete(op.records)
	free(op, a)
}

@(private)
push_write :: proc(d: ^Disk, op: ^Op) {
	sync.mutex_lock(&d.mu)
	append(&d.wq, op)
	sync.cond_broadcast(&d.cond)
	sync.mutex_unlock(&d.mu)
}

@(private)
entry_path :: proc(d: ^Disk, serial: u64, ext: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s\\%016x.%s", d.dir, serial, ext, allocator = allocator)
}

////////////////////////////////
// Loop thread: requests

@(private)
disk_write :: proc(c: ^Cache, e: ^Entry) {
	d := c.disk
	a := heap()
	op := new(Op, a)
	op.kind = .Write
	op.old = e.serial
	op.serial = d.next_serial
	d.next_serial += 1
	op.head = encode_entry_head(e.meta, e.fresh_until, e.body.data)
	op.body = body_retain(e.body)
	op.key = strings.clone(e.key, a)
	if e.serial != 0 { c.disk_bytes -= e.file_size }
	e.serial = op.serial
	e.file_size = i64(len(op.head) + len(e.body.data))
	e.disk = .Writing
	c.disk_bytes += e.file_size
	push_write(d, op)
}

@(private)
disk_delete :: proc(c: ^Cache, serial: u64) {
	op := new(Op, heap())
	op.kind = .Delete
	op.serial = serial
	push_write(c.disk, op)
}

@(private)
disk_clear :: proc(c: ^Cache) {
	op := new(Op, heap())
	op.kind = .Clear
	push_write(c.disk, op)
	c.disk_bytes = 0
	mark_index_dirty(c)
}

@(private)
disk_read :: proc(c: ^Cache, key: string, serial: u64) {
	d := c.disk
	op := new(Op, heap())
	op.kind = .Read
	op.key = strings.clone(key, heap())
	op.serial = serial
	sync.mutex_lock(&d.mu)
	append(&d.rq, op)
	sync.cond_broadcast(&d.cond)
	sync.mutex_unlock(&d.mu)
}

// A snapshot of the entries on disk (or being written), most recently used first.
@(private)
disk_save_index :: proc(c: ^Cache) {
	d := c.disk
	buf := make([dynamic]byte, heap())
	put_u32(&buf, INDEX_MAGIC)
	put_u32(&buf, FORMAT_VERSION)
	put_u64(&buf, d.next_serial)
	count_at := len(buf)
	put_u32(&buf, 0)
	n: u32
	for e := c.head; e != nil; e = e.next {
		if e.disk == .None || e.serial == 0 { continue }
		put_u64(&buf, e.serial)
		put_u64(&buf, u64(e.file_size))
		put_u64(&buf, u64(e.body_size))
		put_u64(&buf, u64(e.last_used_ms))
		put_u64(&buf, u64(e.fresh_until))
		put_u32(&buf, u32(e.status))
		put_str(&buf, e.key)
		put_str(&buf, e.url)
		n += 1
	}
	(^u32le)(&buf[count_at])^ = u32le(n)
	put_u32(&buf, hash.crc32(buf[:]))
	op := new(Op, heap())
	op.kind = .Save_Index
	op.head = buf[:]
	push_write(d, op)
	c.index_dirty = false
}

////////////////////////////////
// Loop thread: results

@(private)
push_done :: proc(d: ^Disk, op: ^Op) {
	sync.mutex_lock(&d.cmu)
	append(&d.done, op)
	post := !d.drain_pending
	d.drain_pending = true
	sync.mutex_unlock(&d.cmu)
	if post { host.post(d.loop, disk_drain, d) }
}

@(private)
disk_drain :: proc(data: rawptr) {
	sync.mutex_lock(&live_mu)
	alive := live[data] or_else false
	sync.mutex_unlock(&live_mu)
	if !alive { return }
	d := (^Disk)(data)
	sync.mutex_lock(&d.cmu)
	ops := slice.clone(d.done[:], context.temp_allocator)
	clear(&d.done)
	d.drain_pending = false
	sync.mutex_unlock(&d.cmu)
	for op in ops {
		c := d.cache
		if c.disk != d { op_free(op); continue }
		switch op.kind {
		case .Load_Index: index_loaded(c, op)
		case .Write:
			if e := find(c, op.key); e != nil && e.serial == op.serial {
				if op.ok {
					e.disk = .Stored
					mark_index_dirty(c)
				} else {
					// could not be written: it stays in memory only
					c.disk_bytes -= e.file_size
					e.disk, e.serial, e.file_size = .None, 0, 0
				}
				trim(c)
			}
		case .Read: read_done(c, op)
		case .Delete, .Save_Index, .Clear:
		}
		op_free(op)
	}
}

@(private)
read_done :: proc(c: ^Cache, op: ^Op) {
	e := find(c, op.key)
	if e != nil && e.serial == op.serial { e.loading = false }
	ok := false
	switch {
	case e == nil:
	case e.resident:
		ok = true
	case e.serial != op.serial:
		// replaced meanwhile by another response of that key (being written: it is resident)
		ok = e.resident
	case op.ok:
		e.meta = op.meta
		op.meta = {}
		e.body = op.read_body
		op.read_body = nil
		e.resident = true
		rlist_push_front(c, e)
		c.resident_bytes += e.body_size
		ok = true
	case:
		c.stats.disk_failures += 1
		remove(c, e)
	}
	key := strings.clone(op.key, context.temp_allocator)
	run_waiters(c, key, ok)
	if ok { trim(c) }
}

@(private)
index_loaded :: proc(c: ^Cache, op: ^Op) {
	d := c.disk
	d.next_serial = max(d.next_serial, op.next_serial)
	// most recently used first: appended in that order at the cold end of what was stored meanwhile
	slice.sort_by(op.records[:], proc(a, b: Index_Record) -> bool { return a.last_used > b.last_used })
	a := heap()
	for &r in op.records {
		if r.key in c.entries {
			disk_delete(c, r.serial)   // a newer response of the key, stored while the index loaded
			op.changed = true
			continue
		}
		e := new(Entry)
		e.key, e.url = r.key, r.url
		r.key, r.url = "", ""
		e.status = r.status
		e.body_size = r.body_size
		e.file_size = r.file_size
		e.serial = r.serial
		e.disk = .Stored
		e.last_used_ms = r.last_used
		e.fresh_until = r.fresh_until
		c.entries[e.key] = e
		list_push_back(c, e)
		c.disk_bytes += e.file_size
	}
	_ = a
	c.ready = true
	if op.changed { mark_index_dirty(c) }
	trim(c)
	run_waiters(c, "", true)
}

////////////////////////////////
// Threads

@(private)
writer_main :: proc(data: rawptr) {
	d := (^Disk)(data)
	context.allocator = heap()
	for {
		sync.mutex_lock(&d.mu)
		for len(d.wq) == 0 && !d.stopping { sync.cond_wait(&d.cond, &d.mu) }
		if len(d.wq) == 0 { sync.mutex_unlock(&d.mu); return }   // stopping, everything written
		op := d.wq[0]
		ordered_remove(&d.wq, 0)
		sync.mutex_unlock(&d.mu)
		switch op.kind {
		case .Load_Index: load_index(d, op)
		case .Write:
			tmp := entry_path(d, op.serial, "tmp")
			final := entry_path(d, op.serial, "wce")
			op.ok = write_file(tmp, {op.head, op.body.data}, false) && replace_file(tmp, final)
			if !op.ok { delete_file(tmp) }
			if op.old != 0 { delete_file(entry_path(d, op.old, "wce")) }
		case .Delete:
			delete_file(entry_path(d, op.serial, "wce"))
		case .Save_Index:
			tmp := strings.concatenate({d.dir, "\\", INDEX_NAME, ".tmp"}, context.temp_allocator)
			final := strings.concatenate({d.dir, "\\", INDEX_NAME}, context.temp_allocator)
			op.ok = write_file(tmp, {op.head}, true) && replace_file(tmp, final)
			if !op.ok { delete_file(tmp) }
		case .Clear:
			for f in list_dir(d.dir) {
				if is_ours(f.name) { delete_file(strings.concatenate({d.dir, "\\", f.name}, context.temp_allocator)) }
			}
		case .Read:
		}
		free_all(context.temp_allocator)
		push_done(d, op)
	}
}

@(private)
reader_main :: proc(data: rawptr) {
	d := (^Disk)(data)
	context.allocator = heap()
	for {
		sync.mutex_lock(&d.mu)
		for len(d.rq) == 0 && !d.stopping { sync.cond_wait(&d.cond, &d.mu) }
		if d.stopping { sync.mutex_unlock(&d.mu); return }
		op := d.rq[0]
		ordered_remove(&d.rq, 0)
		sync.mutex_unlock(&d.mu)
		read_entry(d, op)
		free_all(context.temp_allocator)
		push_done(d, op)
	}
}

@(private)
read_entry :: proc(d: ^Disk, op: ^Op) {
	bytes, ok := read_file(entry_path(d, op.serial, "wce"))
	if !ok { return }
	defer delete(bytes, heap())
	m, body_off, body_len, fresh, good := decode_entry(bytes, true)
	if !good || m.key != op.key { meta_destroy(&m); delete_file(entry_path(d, op.serial, "wce")); return }
	_ = fresh
	data := make([]byte, body_len, heap())
	copy(data, bytes[body_off:][:body_len])
	op.meta = m
	op.read_body = body_make(data)
	op.ok = true
}

////////////////////////////////
// Start-up: the index against the directory

@(private)
load_index :: proc(d: ^Disk, op: ^Op) {
	op.records = make([dynamic]Index_Record, heap())
	op.next_serial = 1
	files := list_dir(d.dir)
	present := make(map[u64]i64, context.temp_allocator)   // serial -> size of <serial>.wce
	for f in files {
		if serial, ok := serial_of(f.name, ".wce"); ok { present[serial] = f.size; continue }
		// temporary files of an interrupted write, and anything of an older format, go
		if strings.has_suffix(f.name, ".tmp") || (is_ours(f.name) && f.name != INDEX_NAME) {
			delete_file(strings.concatenate({d.dir, "\\", f.name}, context.temp_allocator))
		}
	}
	known := make(map[u64]bool, context.temp_allocator)
	idx_path := strings.concatenate({d.dir, "\\", INDEX_NAME}, context.temp_allocator)
	if bytes, ok := read_file(idx_path); ok {
		defer delete(bytes, heap())
		if !decode_index(bytes, op) {
			for &r in op.records { delete(r.key, heap()); delete(r.url, heap()) }
			clear(&op.records)
			op.changed = true
		}
	} else if len(present) > 0 {
		op.changed = true
	}
	// entries whose file is gone or does not have the size the index says
	for i := 0; i < len(op.records); {
		r := op.records[i]
		size, has := present[r.serial]
		if !has || size != r.file_size || r.serial in known {
			if has && r.serial not_in known { delete_file(entry_path(d, r.serial, "wce")) }
			delete(r.key, heap()); delete(r.url, heap())
			unordered_remove(&op.records, i)
			op.changed = true
			continue
		}
		known[r.serial] = true
		op.next_serial = max(op.next_serial, r.serial + 1)
		i += 1
	}
	// files the index does not know: taken back from their own metadata
	seen_keys := make(map[string]int, context.temp_allocator)
	for r, i in op.records { seen_keys[strings.clone(r.key, context.temp_allocator)] = i }
	for serial, size in present {
		if serial in known { continue }
		op.changed = true
		path := entry_path(d, serial, "wce")
		bytes, ok := read_file(path)
		if !ok { continue }
		m, _, body_len, fresh, good := decode_entry(bytes, false)
		delete(bytes, heap())
		if !good { meta_destroy(&m); delete_file(path); continue }
		op.next_serial = max(op.next_serial, serial + 1)
		r := Index_Record{
			serial = serial, file_size = size, body_size = i64(body_len), last_used = m.stored_ms, fresh_until = fresh,
			status = m.status, key = strings.clone(m.key, heap()), url = strings.clone(m.url, heap()),
		}
		meta_destroy(&m)
		if j, dup := seen_keys[r.key]; dup {
			// two files of one key: the later one wins
			old := &op.records[j]
			if old.serial > r.serial { delete_file(path); delete(r.key, heap()); delete(r.url, heap()); continue }
			delete_file(entry_path(d, old.serial, "wce"))
			delete(old.key, heap()); delete(old.url, heap())
			old^ = r
			continue
		}
		seen_keys[strings.clone(r.key, context.temp_allocator)] = len(op.records)
		append(&op.records, r)
	}
	op.ok = true
}

@(private)
serial_of :: proc(name, ext: string) -> (u64, bool) {
	if !strings.has_suffix(name, ext) { return 0, false }
	stem := name[:len(name) - len(ext)]
	if len(stem) != 16 { return 0, false }
	v: u64
	for c in transmute([]u8)stem {
		d: u64
		switch c {
		case '0' ..= '9': d = u64(c - '0')
		case 'a' ..= 'f': d = u64(c - 'a' + 10)
		case: return 0, false
		}
		v = v << 4 | d
	}
	return v, v != 0
}

// Files this cache writes (and only those are ever deleted: the directory may be shared by mistake).
@(private)
is_ours :: proc(name: string) -> bool {
	return name == INDEX_NAME || strings.has_suffix(name, ".wce") || (strings.has_suffix(name, ".tmp") && (len(name) == 20 || name == INDEX_NAME + ".tmp"))
}

////////////////////////////////
// Formats

@(private) put_u32 :: proc(b: ^[dynamic]byte, v: u32) { x := transmute([4]byte)u32le(v); append(b, ..x[:]) }
@(private) put_u64 :: proc(b: ^[dynamic]byte, v: u64) { x := transmute([8]byte)u64le(v); append(b, ..x[:]) }
@(private) put_str :: proc(b: ^[dynamic]byte, s: string) { put_u32(b, u32(len(s))); append(b, s) }

@(private)
Reader :: struct { b: []byte, at: int, bad: bool }

@(private)
get_u32 :: proc(r: ^Reader) -> u32 {
	if r.bad || r.at + 4 > len(r.b) { r.bad = true; return 0 }
	v := (^u32le)(&r.b[r.at])^
	r.at += 4
	return u32(v)
}

@(private)
get_u64 :: proc(r: ^Reader) -> u64 {
	if r.bad || r.at + 8 > len(r.b) { r.bad = true; return 0 }
	v := (^u64le)(&r.b[r.at])^
	r.at += 8
	return u64(v)
}

// A string of the buffer (borrowed).
@(private)
get_str :: proc(r: ^Reader) -> string {
	n := int(get_u32(r))
	if r.bad || n < 0 || r.at + n > len(r.b) { r.bad = true; return "" }
	s := string(r.b[r.at:][:n])
	r.at += n
	return s
}

// The fixed header and the metadata of an entry file (the body follows them).
@(private)
encode_entry_head :: proc(m: Meta, fresh_until: i64, body: []byte) -> []byte {
	meta := make([dynamic]byte, context.temp_allocator)
	put_str(&meta, m.key)
	put_str(&meta, m.url)
	put_u32(&meta, u32(m.status))
	put_str(&meta, m.headers)
	put_str(&meta, m.vary)
	put_u64(&meta, u64(m.request_time))
	put_u64(&meta, u64(m.response_time))
	put_u64(&meta, u64(m.stored_ms))
	put_u64(&meta, u64(fresh_until))
	out := make([dynamic]byte, 0, ENTRY_HEADER + len(meta), heap())
	put_u32(&out, ENTRY_MAGIC)
	put_u32(&out, FORMAT_VERSION)
	put_u32(&out, u32(len(meta)))
	put_u32(&out, hash.crc32(meta[:]))
	put_u64(&out, u64(len(body)))
	put_u32(&out, hash.crc32(body))
	put_u32(&out, 0)
	append(&out, ..meta[:])
	return out[:]
}

// Reads an entry file. `check_body`: the body's checksum too (start-up recovery reads the metadata only). The metadata
// is copied (heap); the body is at bytes[body_off:][:body_len].
@(private)
decode_entry :: proc(bytes: []byte, check_body: bool) -> (m: Meta, body_off, body_len: int, fresh_until: i64, ok: bool) {
	r := Reader{b = bytes}
	if get_u32(&r) != ENTRY_MAGIC || get_u32(&r) != FORMAT_VERSION { return }
	meta_len := int(get_u32(&r))
	meta_crc := get_u32(&r)
	blen := get_u64(&r)
	body_crc := get_u32(&r)
	_ = get_u32(&r)
	if r.bad || meta_len < 0 || ENTRY_HEADER + meta_len > len(bytes) { return }
	if blen != u64(len(bytes) - ENTRY_HEADER - meta_len) { return }   // truncated, or something appended
	meta := bytes[ENTRY_HEADER:][:meta_len]
	if hash.crc32(meta) != meta_crc { return }
	body_off = ENTRY_HEADER + meta_len
	body_len = int(blen)
	if check_body && hash.crc32(bytes[body_off:][:body_len]) != body_crc { return }
	mr := Reader{b = meta}
	key := get_str(&mr)
	u := get_str(&mr)
	status := int(get_u32(&mr))
	headers := get_str(&mr)
	vary := get_str(&mr)
	req := i64(get_u64(&mr))
	resp := i64(get_u64(&mr))
	stored := i64(get_u64(&mr))
	fresh_until = i64(get_u64(&mr))
	if mr.bad { return }
	m = meta_clone(Meta{key = key, url = u, status = status, headers = headers, vary = vary, request_time = req, response_time = resp, stored_ms = stored})
	ok = true
	return
}

@(private)
decode_index :: proc(bytes: []byte, op: ^Op) -> bool {
	if len(bytes) < 24 { return false }
	body := bytes[:len(bytes) - 4]
	if hash.crc32(body) != u32((^u32le)(&bytes[len(bytes) - 4])^) { return false }
	r := Reader{b = body}
	if get_u32(&r) != INDEX_MAGIC || get_u32(&r) != FORMAT_VERSION { return false }
	op.next_serial = max(get_u64(&r), 1)
	n := int(get_u32(&r))
	for _ in 0 ..< n {
		rec: Index_Record
		rec.serial = get_u64(&r)
		rec.file_size = i64(get_u64(&r))
		rec.body_size = i64(get_u64(&r))
		rec.last_used = i64(get_u64(&r))
		rec.fresh_until = i64(get_u64(&r))
		rec.status = int(get_u32(&r))
		k := get_str(&r)
		u := get_str(&r)
		if r.bad { return false }
		rec.key = strings.clone(k, heap())
		rec.url = strings.clone(u, heap())
		append(&op.records, rec)
	}
	return r.at == len(body)
}

////////////////////////////////
// Files (Win32: atomic replacement, no buffering surprises)

@(private)
wide :: proc(s: string) -> win.LPCWSTR { return win.utf8_to_wstring(s, context.temp_allocator) }

@(private)
make_dirs :: proc(dir: string) {
	// every level, from the root (CreateDirectory fails harmlessly on the ones that exist)
	for i in 0 ..< len(dir) {
		if (dir[i] == '\\' || dir[i] == '/') && i > 0 && dir[i - 1] != ':' { win.CreateDirectoryW(wide(dir[:i]), nil) }
	}
	win.CreateDirectoryW(wide(dir), nil)
}

@(private)
write_file :: proc(path: string, parts: [][]byte, flush: bool) -> bool {
	h := win.CreateFileW(wide(path), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return false }
	ok := true
	for p in parts {
		at := 0
		for at < len(p) && ok {
			n: win.DWORD
			chunk := win.DWORD(min(len(p) - at, 1 << 30))
			if !win.WriteFile(h, raw_data(p[at:]), chunk, &n, nil) || n == 0 { ok = false; break }
			at += int(n)
		}
	}
	if ok && flush { ok = bool(win.FlushFileBuffers(h)) }
	win.CloseHandle(h)
	return ok
}

@(private)
replace_file :: proc(from, to: string) -> bool {
	return bool(win.MoveFileExW(wide(from), wide(to), win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH))
}

@(private)
delete_file :: proc(path: string) { win.DeleteFileW(wide(path)) }

// The whole file (heap).
@(private)
read_file :: proc(path: string) -> ([]byte, bool) {
	h := win.CreateFileW(wide(path), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return nil, false }
	defer win.CloseHandle(h)
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(h, &size) || size < 0 || i64(size) > 1 << 40 { return nil, false }
	buf := make([]byte, int(size), heap())
	at := 0
	for at < len(buf) {
		n: win.DWORD
		chunk := win.DWORD(min(len(buf) - at, 1 << 30))
		if !win.ReadFile(h, raw_data(buf[at:]), chunk, &n, nil) || n == 0 { delete(buf, heap()); return nil, false }
		at += int(n)
	}
	return buf, true
}

@(private)
Dir_File :: struct { name: string, size: i64 }

// The plain files of a directory (temp allocator).
@(private)
list_dir :: proc(dir: string) -> []Dir_File {
	out := make([dynamic]Dir_File, context.temp_allocator)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(wide(strings.concatenate({dir, "\\*"}, context.temp_allocator)), &fd)
	if h == win.INVALID_HANDLE_VALUE { return out[:] }
	defer win.FindClose(h)
	for {
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
			n := 0
			for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
			name, _ := win.utf16_to_utf8(fd.cFileName[:n], context.temp_allocator)
			append(&out, Dir_File{name = name, size = i64(fd.nFileSizeHigh) << 32 | i64(fd.nFileSizeLow)})
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return out[:]
}
