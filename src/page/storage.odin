package page

// Web Storage (localStorage, sessionStorage): the profile-wide store behind the "storage" imports.
//
//   * One Storage_Manager per profile, owned by the shell (Embedder.storage). Areas are per origin (localStorage) or per
//     tab and origin (sessionStorage: the shell's tab key; it survives the tab's navigations and is dropped with
//     storage_drop_session when the tab closes). Opaque origins get a SecurityError.
//   * Sizes are counted in UTF-16 code units of keys and values against storage.local.quota / storage.session.quota.
//   * localStorage persists in <profile>/storage/, one file per origin. Areas load lazily: a page that connects starts a
//     background read (storage_prefetch); the first access before it finished reads the file itself. Changes are written
//     storage.local.write_delay_ms later, from a snapshot, on the blocking pool, atomically (temporary file + rename).
//     Writes are ordered per file, so an older snapshot finishing late never replaces a newer one.
//   * A change fires "storage" at the Window of every *other* live page using the same area, from a task of each page.

import "base:runtime"
import "core:encoding/endian"
import "core:os"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:host"
import "wb:url"

Storage_Kind :: enum u8 { Local, Session }

Storage_Item :: struct { key, value: string }   // owned

@(private)
Load_State :: enum u8 { Unloaded, Loading, Loaded }

Storage_Area :: struct {
	id:       string,                // map key (owned)
	origin:   string,                // serialized origin (owned)
	kind:     Storage_Kind,
	items:    [dynamic]Storage_Item, // insertion order: what key(n) walks
	index:    map[string]int,        // key -> position in items
	used:     int,                   // UTF-16 code units of keys and values
	state:    Load_State,
	dirty:    bool,
	changes:  u64,                   // bumped by every change
}

Storage_Manager :: struct {
	dir:         string,                      // "" = localStorage is not persisted
	loop:        ^host.Loop,
	blocking:    ^host.Blocking_Pool,
	areas:       map[string]^Storage_Area,
	write_timer: base.Handle,
	write_seq:   u64,
	pending:     int,                         // background writes not finished
	ready:       bool,
	idb:         ^Idb_Host,                   // IndexedDB of the profile, made on first use (idb_host.odin)
	idb_mu:      sync.Mutex,                  // guards the making of idb (a worker's thread may be the first to need it)
}

// Storage events delivered to pages (diagnostics, tests).
storage_events_delivered: u64

// `dir` is the profile directory ("" = memory only). `blocking` may be nil (writes then happen on the loop thread).
storage_manager_init :: proc(m: ^Storage_Manager, loop: ^host.Loop, blocking: ^host.Blocking_Pool, dir: string) {
	m.loop, m.blocking = loop, blocking
	m.dir = strings.clone(dir) if dir != "" else ""
	m.areas = make(map[string]^Storage_Area)
	m.ready = true
	if m.dir != "" { _ = os.make_directory_all(storage_dir(m)) }
	sw_registry_load(m.dir)   // service_worker.odin: the profile's registrations, the loader's hook
}

// Writes what is not saved yet (synchronously) and frees everything. Pages using the manager must be closed first.
storage_manager_destroy :: proc(m: ^Storage_Manager) {
	if !m.ready { return }
	sw_registry_shutdown()   // service_worker.odin: the workers' host pages use this manager
	// a background write still queued may never run (the blocking pool drops what it has not started when it stops):
	// every area it could be writing is written again here, the commit gate keeps the newest
	storage_flush(m, sync_write = true, all = m.pending > 0)
	idb_host_destroy(m)
	buckets_destroy()
	if m.write_timer != base.NIL_HANDLE { host.clear_timer(m.loop, m.write_timer) }
	for _, a in m.areas { area_free(a) }
	delete(m.areas)
	delete(m.dir)
	m^ = {}
}

// Writes every dirty localStorage area now (on the blocking pool unless `sync_write`; every one with `all`).
storage_flush :: proc(m: ^Storage_Manager, sync_write := false, all := false) {
	if m.dir == "" { return }
	for _, a in m.areas {
		if a.kind != .Local || !(a.dirty || (all && a.state == .Loaded)) { continue }
		a.dirty = false
		area_write(m, a, sync_write)
	}
}

// Forgets the sessionStorage of a tab (call when the tab closes).
storage_drop_session :: proc(m: ^Storage_Manager, tab_key: string) {
	if m == nil || !m.ready { return }
	prefix := strings.concatenate({tab_key, "\x00"}, context.temp_allocator)
	doomed := make([dynamic]string, context.temp_allocator)
	for k, a in m.areas { if a.kind == .Session && strings.has_prefix(k, prefix) { append(&doomed, k) } }
	for k in doomed {
		a := m.areas[k]
		delete_key(&m.areas, k)
		area_free(a)
	}
}

@(private)
area_free :: proc(a: ^Storage_Area) {
	for it in a.items { delete(it.key); delete(it.value) }
	delete(a.items)
	delete(a.index)
	delete(a.id)
	delete(a.origin)
	free(a)
}

@(private)
storage_dir :: proc(m: ^Storage_Manager) -> string {
	return strings.concatenate({m.dir, "/storage"}, context.temp_allocator)
}

// <profile>/storage/<origin with every byte outside [a-z0-9.-] as _XX>.wls
@(private)
area_path :: proc(m: ^Storage_Manager, origin: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, storage_dir(m))
	strings.write_byte(&b, '/')
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(origin) {
		c := origin[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '_'); strings.write_byte(&b, HEX[c >> 4]); strings.write_byte(&b, HEX[c & 15])
		}
	}
	strings.write_string(&b, ".wls")
	return strings.to_string(b)
}

// Length of `s` in UTF-16 code units.
utf16_length :: proc(s: string) -> int {
	n := 0
	for r in s { n += 2 if r >= 0x10000 else 1 }
	return n
}

////////////////////////////////
// File format: "WLS1", u32 count, then count × (u32 key length, key, u32 value length, value), little endian.

@(private)
STORAGE_MAGIC :: "WLS1"

@(private)
area_serialize :: proc(a: ^Storage_Area, allocator: runtime.Allocator) -> []byte {
	size := 8
	for it in a.items { size += 8 + len(it.key) + len(it.value) }
	out := make([]byte, size, allocator)
	copy(out, STORAGE_MAGIC)
	endian.put_u32(out[4:], .Little, u32(len(a.items)))
	o := 8
	for it in a.items {
		endian.put_u32(out[o:], .Little, u32(len(it.key))); o += 4
		copy(out[o:], it.key); o += len(it.key)
		endian.put_u32(out[o:], .Little, u32(len(it.value))); o += 4
		copy(out[o:], it.value); o += len(it.value)
	}
	return out
}

// Fills an empty area from a file image; a damaged file gives what could be read before the damage.
@(private)
area_parse :: proc(a: ^Storage_Area, data: []byte) {
	if len(data) < 8 || string(data[:4]) != STORAGE_MAGIC { return }
	count, _ := endian.get_u32(data[4:], .Little)
	o := 8
	for _ in 0 ..< count {
		if o + 4 > len(data) { return }
		kl, _ := endian.get_u32(data[o:], .Little); o += 4
		if int(kl) > len(data) - o { return }
		key := string(data[o:][:kl]); o += int(kl)
		if o + 4 > len(data) { return }
		vl, _ := endian.get_u32(data[o:], .Little); o += 4
		if int(vl) > len(data) - o { return }
		value := string(data[o:][:vl]); o += int(vl)
		area_put(a, key, value)
	}
}

@(private)
area_put :: proc(a: ^Storage_Area, key, value: string) {
	if i, ok := a.index[key]; ok {
		it := &a.items[i]
		a.used += utf16_length(value) - utf16_length(it.value)
		delete(it.value)
		it.value = strings.clone(value)
		return
	}
	k := strings.clone(key)
	append(&a.items, Storage_Item{k, strings.clone(value)})
	a.index[k] = len(a.items) - 1
	a.used += utf16_length(key) + utf16_length(value)
}

@(private)
area_remove :: proc(a: ^Storage_Area, key: string) -> bool {
	i, ok := a.index[key]
	if !ok { return false }
	it := a.items[i]
	a.used -= utf16_length(it.key) + utf16_length(it.value)
	delete_key(&a.index, it.key)
	ordered_remove(&a.items, i)
	for j in i ..< len(a.items) { a.index[a.items[j].key] = j }
	delete(it.key); delete(it.value)
	return true
}

@(private)
area_clear :: proc(a: ^Storage_Area) {
	for it in a.items { delete(it.key); delete(it.value) }
	clear(&a.items)
	clear(&a.index)
	a.used = 0
}

////////////////////////////////
// Writing: per-file ordering across threads

@(private)
Commit_Gate :: struct {
	mu:   sync.Mutex,
	// file -> sequence number of the newest snapshot on disk, while a write of the file is under way (an entry goes with
	// the last of them: no older snapshot is left to land, and the map never outgrows the writes in flight)
	last: map[string]Gate_Entry,
}

@(private)
Gate_Entry :: struct {
	seq:     u64,
	pending: int,   // writes of the file queued or running (gate_enter .. storage_commit)
}

@(private)
commit_gate: Commit_Gate

// A write of `path` is queued: its entry stays until the write has run (storage_commit). Any thread.
@(private)
gate_enter :: proc(path: string) {
	sync.mutex_lock(&commit_gate.mu)
	defer sync.mutex_unlock(&commit_gate.mu)
	if commit_gate.last == nil { commit_gate.last = make(map[string]Gate_Entry, base.process_allocator()) }
	if e, ok := &commit_gate.last[path]; ok { e.pending += 1; return }
	commit_gate.last[strings.clone(path, base.process_allocator())] = Gate_Entry{pending = 1}
}

// Writes `data` to `path` atomically unless a newer snapshot (higher `seq`) already landed. Any thread; after gate_enter.
@(private)
storage_commit :: proc(path: string, data: []byte, seq: u64) -> (ok: bool) {
	sync.mutex_lock(&commit_gate.mu)
	defer sync.mutex_unlock(&commit_gate.mu)
	e, entered := &commit_gate.last[path]
	assert(entered, "storage_commit without gate_enter")
	defer {
		e.pending -= 1
		if e.pending <= 0 {
			key, _ := delete_key(&commit_gate.last, path)
			delete(key, base.process_allocator())
			if len(commit_gate.last) == 0 { delete(commit_gate.last); commit_gate.last = nil }
		}
	}
	if e.seq >= seq { return true }
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil { return false }
	if os.rename(tmp, path) != nil {
		_ = os.remove(path)
		if os.rename(tmp, path) != nil { return false }
	}
	e.seq = seq
	return true
}
@(private)
Write_Job :: struct {
	path: string,
	data: []byte,
	seq:  u64,
	m:    ^Storage_Manager,   // nil for a synchronous write
}

@(private)
area_write :: proc(m: ^Storage_Manager, a: ^Storage_Area, sync_write: bool) {
	m.write_seq += 1
	job := new(Write_Job, base.process_allocator())
	job.path = strings.clone(area_path(m, a.origin), base.process_allocator())
	job.data = area_serialize(a, base.process_allocator())
	job.seq = m.write_seq
	gate_enter(job.path)
	work :: proc(data: rawptr) {
		j := (^Write_Job)(data)
		context.allocator = base.process_allocator()
		storage_commit(j.path, j.data, j.seq)
	}
	done :: proc(data: rawptr) {
		j := (^Write_Job)(data)
		if j.m != nil && j.m.ready { j.m.pending -= 1 }
		delete(j.path, base.process_allocator())
		delete(j.data, base.process_allocator())
		free(j, base.process_allocator())
	}
	if sync_write || m.blocking == nil {
		work(job)
		done(job)
		return
	}
	job.m = m
	m.pending += 1
	host.run_blocking(m.blocking, work, done, job)
}

@(private)
schedule_write :: proc(m: ^Storage_Manager, delay_ms: f64) {
	if m.dir == "" || m.write_timer != base.NIL_HANDLE { return }
	m.write_timer = host.set_timer(m.loop, delay_ms, 0, proc(data: rawptr) {
		mgr := (^Storage_Manager)(data)
		mgr.write_timer = base.NIL_HANDLE
		storage_flush(mgr)
	}, m)
}

////////////////////////////////
// Loading

@(private)
Load_Job :: struct {
	path:  string,
	id:    string,
	data:  []byte,
	m:     ^Storage_Manager,
	alive: ^bool,
}

// Starts reading the localStorage of `origin` in the background, so that the page's first access finds it loaded.
storage_prefetch :: proc(m: ^Storage_Manager, origin: string) {
	if m == nil || !m.ready || m.dir == "" || m.blocking == nil { return }
	if _, ok := m.areas[origin]; ok { return }
	a := area_new(m, origin, origin, .Local)
	a.state = .Loading
	job := new(Load_Job, base.process_allocator())
	job.path = strings.clone(area_path(m, origin), base.process_allocator())
	job.id = strings.clone(origin, base.process_allocator())
	job.m = m
	host.run_blocking(m.blocking, proc(data: rawptr) {
		j := (^Load_Job)(data)
		bytes, err := os.read_entire_file(j.path, base.process_allocator())
		if err == nil { j.data = bytes }
	}, proc(data: rawptr) {
		j := (^Load_Job)(data)
		defer {
			delete(j.path, base.process_allocator()); delete(j.id, base.process_allocator())
			delete(j.data, base.process_allocator()); free(j, base.process_allocator())
		}
		if !j.m.ready { return }
		a, ok := j.m.areas[j.id]
		if !ok || a.state != .Loading { return }   // read synchronously meanwhile, or dropped
		area_parse(a, j.data)
		a.state = .Loaded
	}, job)
}

@(private)
area_new :: proc(m: ^Storage_Manager, id, origin: string, kind: Storage_Kind) -> ^Storage_Area {
	a := new(Storage_Area)
	a.id, a.origin, a.kind = strings.clone(id), strings.clone(origin), kind
	a.index = make(map[string]int)
	m.areas[a.id] = a
	return a
}

@(private)
area_load_now :: proc(m: ^Storage_Manager, a: ^Storage_Area) {
	if a.state == .Loaded { return }
	a.state = .Loaded
	if a.kind != .Local || m.dir == "" { return }
	data, err := os.read_entire_file(area_path(m, a.origin), context.temp_allocator)
	if err != nil { return }
	area_parse(a, data)
}

////////////////////////////////
// Page side

// The area a page's script reaches as localStorage / sessionStorage, or a SecurityError.
storage_area_of :: proc(p: ^Page, kind: Storage_Kind) -> (^Storage_Area, i32) {
	m := p.web.embedder.storage
	s := &p.settings.web
	if m == nil || !m.ready { return nil, WEB_ERR_SECURITY }
	if kind == .Local && !s.storage_local { return nil, WEB_ERR_SECURITY }
	if kind == .Session && !s.storage_session { return nil, WEB_ERR_SECURITY }
	if p.env.origin.opaque { return nil, WEB_ERR_SECURITY }
	origin := storage_origin_key(p)   // the origin, partitioned by the top-level site for a third-party frame (frames.odin)
	id := origin if kind == .Local else strings.concatenate({p.web.embedder.tab_key, "\x00", origin}, context.temp_allocator)
	a, ok := m.areas[id]
	if !ok { a = area_new(m, id, origin, kind) }
	area_load_now(m, a)
	return a, 0
}

storage_length :: proc(p: ^Page, kind: Storage_Kind) -> (int, i32) {
	a, err := storage_area_of(p, kind)
	if a == nil { return 0, err }
	return len(a.items), 0
}

storage_get_item :: proc(p: ^Page, kind: Storage_Kind, key: string) -> (value: string, found: bool, err: i32) {
	a, e := storage_area_of(p, kind)
	if a == nil { return "", false, e }
	i, ok := a.index[key]
	if !ok { return "", false, 0 }
	return a.items[i].value, true, 0
}

storage_key :: proc(p: ^Page, kind: Storage_Kind, n: int) -> (key: string, found: bool, err: i32) {
	a, e := storage_area_of(p, kind)
	if a == nil { return "", false, e }
	if n < 0 || n >= len(a.items) { return "", false, 0 }
	return a.items[n].key, true, 0
}

storage_set_item :: proc(p: ^Page, kind: Storage_Kind, key, value: string) -> i32 {
	a, err := storage_area_of(p, kind)
	if a == nil { return err }
	old: string
	had := false
	if i, ok := a.index[key]; ok { old, had = a.items[i].value, true }
	if had && old == value { return 0 }
	quota := p.settings.web.storage_quota if kind == .Local else p.settings.web.session_quota
	next := a.used + utf16_length(value) + (utf16_length(key) if !had else -utf16_length(old))
	if next > quota { return WEB_ERR_QUOTA }
	old_copy := strings.clone(old, context.temp_allocator)
	area_put(a, key, value)
	area_changed(p, a)
	storage_broadcast(p, a, key, old_copy, value, had ? 0 : 2)
	return 0
}

storage_remove_item :: proc(p: ^Page, kind: Storage_Kind, key: string) -> i32 {
	a, err := storage_area_of(p, kind)
	if a == nil { return err }
	i, ok := a.index[key]
	if !ok { return 0 }
	old := strings.clone(a.items[i].value, context.temp_allocator)
	area_remove(a, key)
	area_changed(p, a)
	storage_broadcast(p, a, key, old, "", 4)
	return 0
}

storage_clear :: proc(p: ^Page, kind: Storage_Kind) -> i32 {
	a, err := storage_area_of(p, kind)
	if a == nil { return err }
	if len(a.items) == 0 { return 0 }
	area_clear(a)
	area_changed(p, a)
	storage_broadcast(p, a, "", "", "", 1 | 2 | 4)
	return 0
}

@(private)
area_changed :: proc(p: ^Page, a: ^Storage_Area) {
	a.changes += 1
	if a.kind != .Local { return }
	a.dirty = true
	schedule_write(p.web.embedder.storage, p.settings.web.storage_write_delay_ms)
}

@(private)
Storage_Event_Task :: struct {
	kind:                           Storage_Kind,
	key, old_value, new_value, url: string,
	flags:                          u8,
}

// Queues "storage" at the other pages that see the same area (same manager, origin, and tab for sessionStorage).
@(private)
storage_broadcast :: proc(src: ^Page, a: ^Storage_Area, key, old_value, new_value: string, flags: u8) {
	m := src.web.embedder.storage
	for q in live_page_list() {
		if q == src || q.web.embedder.storage != m || q.env.origin.opaque { continue }
		if !url.same_origin(q.env.origin, src.env.origin) || storage_origin_key(q) != storage_origin_key(src) { continue }
		if a.kind == .Session && q.web.embedder.tab_key != src.web.embedder.tab_key { continue }
		t := new(Storage_Event_Task)
		t^ = Storage_Event_Task{kind = a.kind, key = strings.clone(key), old_value = strings.clone(old_value),
			new_value = strings.clone(new_value), url = strings.clone(src.env.location.href), flags = flags}
		post_page_task(q, proc(pg: ^Page, data: rawptr) {
			t := (^Storage_Event_Task)(data)
			defer { delete(t.key); delete(t.old_value); delete(t.new_value); delete(t.url); free(t) }
			if pg == nil { return }
			storage_events_delivered += 1
			push_event_detail(pg, Event_Detail{type = "storage", key = t.key, old_value = t.old_value, new_value = t.new_value,
				url = t.url, area = u64(t.kind), flags = t.flags})
			fire_window_event(pg, {type = "storage", data = t.key, text = t.new_value})
			if !pg.closed { pop_event_detail(pg) }
		}, t)
	}
}

// web_destroy: a localStorage area nobody else uses and with nothing to save is unloaded.
@(private)
storage_page_closed :: proc(p: ^Page) {
	m := p.web.embedder.storage
	if m == nil || !m.ready || p.env.origin.opaque { return }
	origin := storage_origin_key(p)
	a, ok := m.areas[origin]
	if !ok || a.dirty || a.state != .Loaded || m.pending > 0 { return }   // a write in flight: the file may be older than memory
	for q in live_page_list() {
		if q != p && q.web.embedder.storage == m && !q.env.origin.opaque && url.same_origin(q.env.origin, p.env.origin) && storage_origin_key(q) == origin { return }
	}
	delete_key(&m.areas, origin)
	area_free(a)
}
