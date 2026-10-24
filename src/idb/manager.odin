package idb

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"

// Everything that is shared between the pages (realms) of a profile: the origins' data, their journal files, the
// connections to databases, the transactions and the order they run in, the open / delete requests of a database and the
// versionchange handshake between connections. It lives on one thread (the page thread); only the disk work runs elsewhere,
// through `submit`.
//
// A realm is a Client. What happens to it later is delivered as Events in its queue (client_pop), one per task: the
// realm runs the script's handlers for one event, then the microtask checkpoint, then the next.
//
//   * Origins load lazily (a read and replay of the journal on the pool) and are dropped from memory after
//     idle_unload_ms without an open connection (manager_tick). Requests wait for the load.
//   * A database has a queue of open and delete requests handled one at a time (the specification's connection
//     queue): an open for a higher version sends "versionchange" to the other connections, "blocked" to its own request
//     if some are still open after their handlers ran, waits for them to close, runs the upgrade transaction and then
//     succeeds (or fails if that transaction aborts or the connection was closed meanwhile).
//   * Transactions run in the order they were created: one starts when no earlier unfinished transaction of the
//     database has an overlapping scope with a writing mode on either side. A transaction keeps its scope until its
//     journal record is on disk: if the write fails it is rolled back (it was the only one that could see its changes).
//   * Journal writes are queued per origin, one in flight, consecutive records written together.

Submit_Proc :: #type proc(user: rawptr, work, done: proc(data: rawptr), data: rawptr)
Post_Proc :: #type proc(user: rawptr, fn: proc(data: rawptr), data: rawptr)

Tx_Mode :: enum u8 { Read_Only, Read_Write, Version_Change }

Event_Kind :: enum u8 {
	None,
	Task,             // a: token given to client_post_task
	Open_Upgrade,     // req, conn, tx, v1 (old version), v2 (new), data (metadata)
	Open_Done,        // req, conn, v1 (version), data (metadata)
	Open_Error,       // req, err
	Blocked,          // req, v1 (old), v2 (new; 0 for a deletion)
	Version_Change,   // conn, v1 (old), v2 (new; 0 for a deletion)
	Delete_Done,      // req, v1 (version deleted; 0 if none)
	Delete_Error,     // req, err
	Tx_Started,       // tx
	Tx_Complete,      // tx
	Tx_Aborted,       // tx, err
	Conn_Closed,      // conn: closed by the browser (site data cleared)
	List,             // req, data (count, then name and version of each)
}

Event :: struct {
	kind:           Event_Kind,
	req, conn, tx:  u64,
	v1, v2, a:      u64,
	err:            Error,
	data:           []byte,   // owned until client_event_free
}

Client :: struct {
	id:           u64,
	m:            ^Manager,
	origin:       string,
	queue:        [dynamic]Event,
	head:         int,
	wake:         proc(c: ^Client),
	user:         rawptr,
	wake_pending: bool,
	conns:        [dynamic]^Connection,
	dead:         bool,
}

Connection :: struct {
	id:            u64,
	client:        ^Client,
	o:             ^Origin,
	ds:            ^Db_State,
	closed:        bool,
	close_pending: bool,
	live_txs:      int,
	version:       u64,
	refs:          int,    // the registries (1), a request waiting for its handler (1), the request it opened for (1)
}

Tx :: struct {
	id:        u64,
	conn:      ^Connection,
	ds:        ^Db_State,
	mode:      Tx_Mode,
	scope:     [dynamic]u32,
	state:     Tx_State,
	undo:      Undo_Log,
	redo:      Writer,
	x:         Exec,
	strict:    bool,
	upgrade:   ^Request,   // the open request this versionchange transaction belongs to
	system:    ^Request,   // a deletion's own record
	client:    ^Client,    // who is told how it ends (nil: nobody)
	stale:     bool,       // the origin's data was cleared while this one was being written: nothing to roll back
	values:    [dynamic]Value_Ref,   // the values it put (their place in the journal is known once it is written)
}

Tx_State :: enum u8 { Pending, Active, Committing, Finished }

Request_Kind :: enum u8 { Open, Delete }

Request :: struct {
	id:         u64,
	kind:       Request_Kind,
	client:     ^Client,
	name:       string,
	version:    u64,
	has_version: bool,
	old_version, new_version: u64,
	waiting_ack: [dynamic]^Connection,   // connections whose versionchange handlers have not run yet
	waiting:    bool,                    // versionchange sent: waiting for the others to close
	blocked_sent: bool,
	writing:    bool,                    // a deletion whose journal record is being written (its transaction points back here)
	conn:       ^Connection,
	tx:         ^Tx,
	cancelled:  bool,                    // its client is gone
}

Db_State :: struct {
	o:       ^Origin,
	name:    string,
	conns:   [dynamic]^Connection,
	queue:   [dynamic]^Request,
	active:  ^Request,
	txs:     [dynamic]^Tx,
}

Origin_State :: enum u8 { Loading, Ready }

Write_Item :: struct {
	tx:     ^Tx,        // nil: a snapshot replaces the file
	data:   []byte,     // the framed record(s) (owned)
	strict: bool,
}

Origin :: struct {
	m:           ^Manager,
	key:         string,
	stem:        string,    // <profile>/idb/<escaped key>: the files are this and a generation and an extension
	state:       Origin_State,
	data:        Data,
	dbs:         map[string]^Db_State,
	file_len:    i64,       // where the next record goes (the journal's length); 0: the header is still to write
	alien:       bool,      // the file is something else: nothing is written
	jfile:       File,      // the journal of generation jgen (invalid until something is written)
	jgen:        u32,
	vsrc:        Value_Source,   // where Data reads values: the journal files by generation parity
	wq:          [dynamic]Write_Item,
	writing:     bool,      // a write is on the pool
	flush_posted: bool,     // a task will write what is queued
	hold_writes: bool,      // commits wait: a compaction is switching to its files
	dirty_txs:   int,       // transactions holding changes not yet on disk
	unsynced:    i64,       // bytes written that the system may still hold (relaxed durability)
	sync_busy:   bool,
	ck_len:      i64,       // the journal length the checkpoint stands for (0: none)
	ck_busy:     bool,      // a checkpoint is being written
	loads:       int,       // reads of stores in flight
	epoch:       u32,       // bumped when the data is cleared: results of jobs started before are dropped
	compaction:  ^Compaction,
	compact_retry: i64,     // after a failed compaction: not again before the journal is this long
	clear_pending: bool,    // site data was cleared while a write was on the pool: the files go when it ends
	idle_since:  f64,       // ms; 0 while in use
	pending_load: ^Load_Job,
	clients:     int,
	list_waits:  [dynamic]List_Wait,   // databases() asked before the load finished
	clear_on_load: bool,               // site data was cleared while the file was being read
}
List_Wait :: struct { client_id, req: u64 }

Life :: struct { refs: int, alive: bool }

Manager :: struct {
	settings:   Settings,
	dir:        string,          // "" = memory only
	submit:     Submit_Proc,
	submit_user: rawptr,
	allocator:  runtime.Allocator,
	origins:    map[string]^Origin,
	conns:      map[u64]^Connection,
	txs:        map[u64]^Tx,
	clients:    map[u64]^Client,
	next_id:    u64,
	life:       ^Life,
	now_ms:     proc() -> f64,
	post:       Post_Proc,        // runs a function later on the thread of the shell's loop (nil: at once)
	post_user:  rawptr,
	stats:      Stats,
	mu:         sync.Recursive_Mutex,   // every entry point takes it: pages and workers (threads of their own) share the manager
}

Stats :: struct {
	loads, appends, snapshots, bytes_written: u64,
	rollbacks, commits: u64,
}

manager_init :: proc(m: ^Manager, settings: Settings, dir: string, submit: Submit_Proc, submit_user: rawptr, now_ms: proc() -> f64, allocator: runtime.Allocator = {}) {
	alloc := allocator
	if alloc.procedure == nil { alloc = base.process_allocator() }
	m^ = {settings = settings, submit = submit, submit_user = submit_user, allocator = alloc, now_ms = now_ms}
	context.allocator = alloc
	m.dir = strings.clone(dir) if dir != "" else ""
	m.origins = make(map[string]^Origin)
	m.conns = make(map[u64]^Connection)
	m.txs = make(map[u64]^Tx)
	m.clients = make(map[u64]^Client)
	m.life = new(Life, base.process_allocator())
	m.life.refs = 1
	m.life.alive = true
	if m.dir != "" { os.make_directory_all(join_path(m.dir, "idb")) }
}

@(private)
join_path :: proc(a, b: string) -> string { return strings.concatenate({a, "/", b}, context.temp_allocator) }

// The client a connection / a transaction belongs to (nil: unknown).
conn_client :: proc(m: ^Manager, id: u64) -> ^Client {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	if conn, ok := m.conns[id]; ok { return conn.client }
	return nil
}

tx_client :: proc(m: ^Manager, id: u64) -> ^Client {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	if tx, ok := m.txs[id]; ok { return tx.client }
	return nil
}

// How the manager runs something later on the thread of the shell's loop (the grouping of commits, slices of a remap).
manager_set_post :: proc(m: ^Manager, post: Post_Proc, user: rawptr) {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	m.post, m.post_user = post, user
}

// What an origin (storage key) holds: the bytes its records count against the quota, its databases. loaded false: not in memory.
manager_usage :: proc(m: ^Manager, key: string) -> (bytes: i64, dbs: int, loaded: bool) {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	o, ok := m.origins[key]
	if !ok || o.state != .Ready { return 0, 0, false }
	return o.data.bytes, len(o.data.dbs), true
}

// The keys of the origins in memory.
manager_loaded_keys :: proc(m: ^Manager, allocator: runtime.Allocator) -> []string {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	out := make([dynamic]string, 0, len(m.origins), allocator)
	for k in m.origins { append(&out, strings.clone(k, allocator)) }
	return out[:]
}

// The settings in force (a realm's: it may differ from the one that made the manager).
manager_set_settings :: proc(m: ^Manager, s: Settings) {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	m.settings = s
}

life_unref :: proc(l: ^Life) {
	if sync.atomic_sub(&l.refs, 1) == 1 { free(l, base.process_allocator()) }
}

// Rolls back what is not committed, writes what is waiting (synchronously: the pool may be gone), writes the checkpoints, frees
// everything. Clients must be destroyed first.
manager_destroy :: proc(m: ^Manager) {
	context.allocator = m.allocator
	for _, o in m.origins {
		for _, ds in o.dbs {
			txs := slice.clone(ds.txs[:], context.temp_allocator)
			for tx in txs { if tx.state == .Pending || tx.state == .Active { tx_rollback(m, tx) } }
		}
		origin_shutdown(m, o)
		origin_free(m, o)
	}
	delete(m.origins)
	delete(m.conns); delete(m.txs); delete(m.clients)
	delete(m.dir)
	m.life.alive = false
	life_unref(m.life)
	m^ = {}
}
////////////////////////////////
// Clients

client_create :: proc(m: ^Manager, origin: string, wake: proc(c: ^Client), user: rawptr) -> ^Client {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	context.allocator = m.allocator
	c := new(Client)
	m.next_id += 1
	c.id = m.next_id
	c.m = m
	c.origin = strings.clone(origin)
	c.wake, c.user = wake, user
	c.queue = make([dynamic]Event)
	c.conns = make([dynamic]^Connection)
	m.clients[c.id] = c
	o := origin_get(m, origin)
	o.clients += 1
	o.idle_since = 0
	return c
}

// The realm is gone: its connections close, its transactions that had not committed roll back, its requests are dropped.
client_destroy :: proc(c: ^Client) {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	c.dead = true
	o := m.origins[c.origin]
	// requests first (an upgrade in progress is aborted), then connections
	if o != nil {
		for _, ds in o.dbs {
			if ds.active != nil && ds.active.client == c {
				req := ds.active
				req.cancelled = true
				req.client = nil
				if req.tx != nil && req.tx.state != .Finished && req.tx.state != .Committing { tx_rollback(m, req.tx) }
			}
			for i := len(ds.queue) - 1; i >= 0; i -= 1 {
				if ds.queue[i].client == c { request_free(ds.queue[i]); ordered_remove(&ds.queue, i) }
			}
		}
	}
	conns := slice.clone(c.conns[:], context.temp_allocator)
	for conn in conns {
		txs := slice.clone(conn.ds.txs[:], context.temp_allocator)
		for tx in txs {
			if tx.conn == conn {
				tx.client = nil
				if tx.state == .Pending || tx.state == .Active { tx_rollback(m, tx) }
			}
		}
	}
	for conn in conns {
		conn.close_pending = true
		conn_try_close(m, conn)
	}
	for conn in c.conns { conn.client = nil }   // still open: a transaction of it is being written
	if o != nil {
		for _, ds in o.dbs { db_pump(o, ds) }
		o.clients -= 1
		if o.clients <= 0 && m.now_ms != nil { o.idle_since = m.now_ms() }
	}
	for i in c.head ..< len(c.queue) { event_free(c, &c.queue[i]) }
	delete(c.queue)
	delete(c.conns)
	delete(c.origin)
	delete_key(&m.clients, c.id)
	free(c)
}

client_post_task :: proc(c: ^Client, token: u64) {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	push_event(c, Event{kind = .Task, a = token})
}

client_has_events :: proc(c: ^Client) -> bool {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	return c.head < len(c.queue)
}

// The next event; the caller releases it with event_free.
client_pop :: proc(c: ^Client) -> (ev: Event, ok: bool) {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	if c.head >= len(c.queue) { c.wake_pending = false; return {}, false }
	ev = c.queue[c.head]
	c.head += 1
	if c.head == len(c.queue) { clear(&c.queue); c.head = 0; c.wake_pending = false }
	return ev, true
}

event_free :: proc(c: ^Client, ev: ^Event) { delete(ev.data, c.m.allocator); ev.data = nil }

@(private)
push_event :: proc(c: ^Client, ev: Event) {
	if c == nil || c.dead {
		delete(ev.data, context.allocator)   // (every caller runs with the manager's allocator)
		return
	}
	context.allocator = c.m.allocator
	append(&c.queue, ev)
	if !c.wake_pending {
		c.wake_pending = true
		if c.wake != nil { c.wake(c) }
	}
}

////////////////////////////////
// Origins

// <profile>/idb/<key with every byte outside [a-z0-9.-] as _XX>: the files of the origin are this, a generation and an extension.
origin_stem :: proc(m: ^Manager, key: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, m.dir)
	strings.write_string(&b, "/idb/")
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(key) {
		c := key[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '_'); strings.write_byte(&b, HEX[c >> 4]); strings.write_byte(&b, HEX[c & 15])
		}
	}
	return strings.to_string(b)
}

// The journal file of generation `gen` (and, with ".widx", the checkpoint).
origin_file :: proc(o: ^Origin, gen: u32, ext := ".widb", allocator := context.temp_allocator) -> string {
	return generation_name(o.stem, gen, ext, allocator)
}

@(private)
Load_Job :: struct {
	dir:    string,
	name:   string,   // the stem's last part
	result: Origin_Load,
	life:   ^Life,
	o:      ^Origin,
	m:      ^Manager,
}

@(private)
origin_get :: proc(m: ^Manager, key: string) -> ^Origin {
	if o, ok := m.origins[key]; ok { return o }
	context.allocator = m.allocator
	o := new(Origin)
	o.m = m
	o.key = strings.clone(key)
	o.dbs = make(map[string]^Db_State)
	o.wq = make([dynamic]Write_Item)
	o.list_waits = make([dynamic]List_Wait)
	m.origins[o.key] = o
	if m.dir == "" {
		data_init(&o.data, m.allocator)
		o.data.cache_limit = m.settings.value_cache_bytes
		o.state = .Ready
		return o
	}
	o.stem = strings.clone(origin_stem(m, key))
	o.state = .Loading
	job := new(Load_Job, base.process_allocator())
	slash := strings.last_index_byte(o.stem, '/')
	job.dir = strings.clone(o.stem[:slash], base.process_allocator())
	job.name = strings.clone(o.stem[slash + 1:], base.process_allocator())
	job.life = m.life
	sync.atomic_add(&m.life.refs, 1)
	job.o, job.m = o, m
	o.pending_load = job
	m.stats.loads += 1
	run :: proc(data: rawptr) {
		j := (^Load_Job)(data)
		context.allocator = base.process_allocator()
		j.result = load_origin(j.dir, j.name, base.process_allocator())
	}
	finish :: proc(data: rawptr) {
		j := (^Load_Job)(data)
		defer {
			delete(j.dir, base.process_allocator())
			delete(j.name, base.process_allocator())
			life_unref(j.life)
			free(j, base.process_allocator())
		}
		if !j.life.alive {
			data_destroy(&j.result.data)
			file_close(&j.result.jfile)
			return
		}
		o := j.o
		sync.recursive_mutex_lock(&j.m.mu); defer sync.recursive_mutex_unlock(&j.m.mu)
		context.allocator = j.m.allocator
		o.pending_load = nil
		r := &j.result
		o.data = r.data
		o.alien = r.alien
		o.jgen, o.file_len, o.ck_len = r.jgen, r.good_len, r.ck_len
		o.jfile = r.jfile
		o.vsrc.files[r.jgen & 1] = r.jfile
		o.data.vsrc = &o.vsrc
		o.data.cache_limit = j.m.settings.value_cache_bytes
		if o.clear_on_load {
			origin_wipe(j.m, o)
			o.clear_on_load = false
		}
		o.state = .Ready
		answer_lists(o)
		for _, ds in o.dbs { db_pump(o, ds) }
	}
	if m.submit != nil {
		m.submit(m.submit_user, run, finish, job)
	} else {
		run(job)
		finish(job)
	}
	return o
}

@(private)
origin_free :: proc(m: ^Manager, o: ^Origin) {
	context.allocator = m.allocator
	for _, ds in o.dbs { db_state_free(ds) }
	delete(o.dbs)
	data_destroy(&o.data)
	for it in o.wq { delete(it.data) }
	delete(o.wq)
	delete(o.list_waits)
	for i in 0 ..< 2 { file_close(&o.vsrc.files[i]) }
	o.jfile = {}
	free(o.compaction)
	delete(o.key)
	delete(o.stem)
	free(o)
}
@(private)
db_state :: proc(o: ^Origin, name: string) -> ^Db_State {
	if ds, ok := o.dbs[name]; ok { return ds }
	context.allocator = o.m.allocator
	ds := new(Db_State)
	ds.o = o
	ds.name = strings.clone(name)
	o.dbs[ds.name] = ds
	return ds
}

@(private)
db_state_free :: proc(ds: ^Db_State) {
	for c in ds.conns { c.refs = 1; conn_unref(c) }
	for t in ds.txs { tx_free(t) }
	for r in ds.queue { request_free(r) }
	if ds.active != nil { request_free(ds.active) }
	delete(ds.conns); delete(ds.txs); delete(ds.queue)
	delete(ds.name)
	free(ds)
}

// Housekeeping, from a timer: what the system holds of the journals is flushed (relaxed durability), the stores nobody uses
// are dropped from memory, and so are the origins nobody uses (their checkpoint is written first: the next opening reads
// keys, not the journal).
manager_tick :: proc(m: ^Manager) -> (loaded: int) {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	context.allocator = m.allocator
	if m.now_ms == nil || m.dir == "" { return len(m.origins) }
	now := m.now_ms()
	doomed := make([dynamic]string, context.temp_allocator)
	for k, o in m.origins {
		if o.state != .Ready { continue }
		origin_sync_maybe(m, o, now)
		evict_stores(m, o, now)
		if o.clients > 0 || o.writing || len(o.wq) > 0 || o.dirty_txs > 0 || o.ck_busy || o.loads > 0 || o.compaction != nil || o.sync_busy { continue }
		busy := false
		for _, ds in o.dbs { if len(ds.conns) > 0 || len(ds.queue) > 0 || ds.active != nil || len(ds.txs) > 0 { busy = true } }
		if busy { continue }
		if o.idle_since == 0 { o.idle_since = now; continue }
		if now - o.idle_since >= m.settings.idle_unload_ms {
			if origin_checkpoint_due(m, o, true) {
				maybe_checkpoint(m, o, true)   // (written in the background: the origin goes at a later tick)
				continue
			}
			append(&doomed, k)
		}
	}
	for k in doomed {
		o := m.origins[k]
		delete_key(&m.origins, k)
		if file_valid(o.jfile) && o.unsynced > 0 { file_sync(o.jfile) }
		origin_free(m, o)
	}
	return len(m.origins)
}
////////////////////////////////
// Opening and deleting databases

open_database :: proc(c: ^Client, name: string, version: u64, has_version: bool) -> u64 {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	o := origin_get(m, c.origin)
	ds := db_state(o, name)
	req := new(Request)
	m.next_id += 1
	req.id = m.next_id
	req.kind = .Open
	req.client = c
	req.name = strings.clone(name)
	req.version, req.has_version = version, has_version
	append(&ds.queue, req)
	db_pump(o, ds)
	return req.id
}

delete_database :: proc(c: ^Client, name: string) -> u64 {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	o := origin_get(m, c.origin)
	ds := db_state(o, name)
	req := new(Request)
	m.next_id += 1
	req.id = m.next_id
	req.kind = .Delete
	req.client = c
	req.name = strings.clone(name)
	append(&ds.queue, req)
	db_pump(o, ds)
	return req.id
}

// The names and versions of the origin's databases, as a List event.
list_databases :: proc(c: ^Client) -> u64 {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	m.next_id += 1
	id := m.next_id
	o := origin_get(m, c.origin)
	// a list waits for the load like everything else: it is answered from a task once the origin is ready
	w: Writer
	if o.state == .Ready {
		encode_list(&w, o)
		push_event(c, Event{kind = .List, req = id, data = w.data[:]})
	} else {
		append(&o.list_waits, List_Wait{c.id, id})
	}
	return id
}

@(private)
request_free :: proc(r: ^Request) {
	delete(r.name)
	delete(r.waiting_ack)
	free(r)
}

// Runs requests of the database while none is active.
@(private)
db_pump :: proc(o: ^Origin, ds: ^Db_State) {
	if o.state != .Ready { return }
	for {
		if ds.active != nil {
			check_active(o, ds)
			if ds.active != nil { return }
		}
		if len(ds.queue) == 0 { return }
		req := ds.queue[0]
		ordered_remove(&ds.queue, 0)
		if req.client == nil || req.client.dead { request_free(req); continue }
		ds.active = req
		switch req.kind {
		case .Open: start_open(o, ds, req)
		case .Delete: start_delete(o, ds, req)
		}
	}
}

// Whether something is on its way to the client (an event in its queue, the origin's file being read or written): a page
// waiting for IndexedDB is not idle (test tools use this to tell it from one with nothing left to do).
client_busy :: proc(c: ^Client) -> bool {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	if c.head < len(c.queue) { return true }
	o, ok := c.m.origins[c.origin]
	return ok && (o.state == .Loading || o.writing || len(o.wq) > 0 || o.loads > 0 || o.flush_posted)
}
