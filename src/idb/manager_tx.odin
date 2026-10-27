package idb

import "core:slice"
import "core:strings"
import "core:sync"

// Connections, the open / delete handshake, transactions and the journal writer of the Manager (manager.odin).

////////////////////////////////
// Metadata: what a connection's script is told about the schema

encode_metadata :: proc(w: ^Writer, db: ^Database) {
	w_uv(w, db.version)
	w_uv(w, u64(len(db.stores)))
	for s in db.stores {
		w_uv(w, u64(s.id)); w_str(w, s.name); w_bytes(w, s.key_path); w_u8(w, 1 if s.auto_increment else 0)
		w_uv(w, u64(len(s.indexes)))
		for ix in s.indexes {
			w_uv(w, u64(ix.id)); w_str(w, ix.name); w_bytes(w, ix.key_path)
			w_u8(w, (1 if ix.unique else 0) | (2 if ix.multi else 0))
		}
	}
}

@(private)
metadata_bytes :: proc(m: ^Manager, db: ^Database) -> []byte {
	context.allocator = m.allocator
	w: Writer
	encode_metadata(&w, db)
	return w.data[:]
}

// The databases databases() lists: those that exist at the last commit (one being created by a running upgrade is not there yet,
// one being upgraded still has its old version).
@(private)
encode_list :: proc(w: ^Writer, o: ^Origin) {
	n := 0
	for db in o.data.dbs { if _, ok := committed_version(o, db); ok { n += 1 } }
	w_uv(w, u64(n))
	for db in o.data.dbs {
		if v, ok := committed_version(o, db); ok { w_str(w, db.name); w_uv(w, v) }
	}
}

@(private)
committed_version :: proc(o: ^Origin, db: ^Database) -> (u64, bool) {
	if ds, ok := o.dbs[db.name]; ok && ds.active != nil && ds.active.kind == .Open && ds.active.tx != nil {
		return ds.active.old_version, ds.active.old_version != 0
	}
	return db.version, true
}

@(private)
answer_lists :: proc(o: ^Origin) {
	m := o.m
	context.allocator = m.allocator
	for wait in o.list_waits {
		c, ok := m.clients[wait.client_id]
		if !ok { continue }
		w: Writer
		encode_list(&w, o)
		push_event(c, Event{kind = .List, req = wait.req, data = w.data[:]})
	}
	clear(&o.list_waits)
}

////////////////////////////////
// Connections

@(private)
conn_new :: proc(m: ^Manager, c: ^Client, o: ^Origin, ds: ^Db_State, version: u64) -> ^Connection {
	context.allocator = m.allocator
	conn := new(Connection)
	m.next_id += 1
	conn.id = m.next_id
	conn.client, conn.o, conn.ds, conn.version = c, o, ds, version
	conn.refs = 1
	append(&ds.conns, conn)
	append(&c.conns, conn)
	m.conns[conn.id] = conn
	return conn
}

@(private)
conn_unref :: proc(conn: ^Connection) {
	conn.refs -= 1
	if conn.refs <= 0 { free(conn) }
}

// Closes a connection that asked to be closed once its transactions are over.
@(private)
conn_try_close :: proc(m: ^Manager, conn: ^Connection) {
	if conn.closed || !conn.close_pending || conn.live_txs > 0 { return }
	conn.closed = true
	ds := conn.ds
	for x, i in ds.conns { if x == conn { ordered_remove(&ds.conns, i); break } }
	if c := conn.client; c != nil {
		for x, i in c.conns { if x == conn { ordered_remove(&c.conns, i); break } }
	}
	delete_key(&m.conns, conn.id)
	conn_unref(conn)
}

// connection.close(): no new transaction; it closes when the running ones have finished.
close_connection :: proc(c: ^Client, id: u64) -> Error {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	conn, ok := m.conns[id]
	if !ok || conn.client != c { return .Not_Found }
	conn.close_pending = true
	conn_try_close(m, conn)
	db_pump(conn.o, conn.ds)
	return .None
}

// The script's "versionchange" handlers of the connection have run.
versionchange_done :: proc(c: ^Client, id: u64) {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	conn, ok := m.conns[id]
	if !ok || conn.client != c { return }
	ds := conn.ds
	if req := ds.active; req != nil {
		for x, i in req.waiting_ack {
			if x == conn { ordered_remove(&req.waiting_ack, i); conn_unref(conn); break }
		}
	}
	db_pump(conn.o, ds)
}

////////////////////////////////
// Open

@(private)
fail_request :: proc(o: ^Origin, ds: ^Db_State, req: ^Request, err: Error) {
	kind: Event_Kind = .Open_Error if req.kind == .Open else .Delete_Error
	push_event(req.client, Event{kind = kind, req = req.id, err = err})
	request_done(ds, req)
}

@(private)
request_done :: proc(ds: ^Db_State, req: ^Request) {
	for conn in req.waiting_ack { conn_unref(conn) }
	clear(&req.waiting_ack)
	if req.conn != nil { conn_unref(req.conn); req.conn = nil }
	if ds.active == req { ds.active = nil }
	request_free(req)
}

@(private)
start_open :: proc(o: ^Origin, ds: ^Db_State, req: ^Request) {
	m := o.m
	db := find_db(&o.data, req.name)
	cur: u64 = db.version if db != nil else 0
	want := req.version
	if !req.has_version { want = cur if cur > 0 else 1 }
	if cur > want { fail_request(o, ds, req, .Version); return }
	if db == nil && len(o.data.dbs) >= m.settings.max_databases { fail_request(o, ds, req, .Quota); return }
	req.old_version, req.new_version = cur, want
	if cur == want {
		conn := conn_new(m, req.client, o, ds, want)
		push_event(req.client, Event{kind = .Open_Done, req = req.id, conn = conn.id, v1 = want, data = metadata_bytes(m, db)})
		request_done(ds, req)
		return
	}
	send_versionchange(m, ds, req, cur, want)
}

@(private)
send_versionchange :: proc(m: ^Manager, ds: ^Db_State, req: ^Request, old, new: u64) {
	req.waiting = true
	for conn in ds.conns {
		if conn.closed || conn.close_pending { continue }
		push_event(conn.client, Event{kind = .Version_Change, conn = conn.id, v1 = old, v2 = new})
		conn.refs += 1
		append(&req.waiting_ack, conn)
	}
}

// Moves the active request on when the connections it was waiting for have answered and closed.
@(private)
check_active :: proc(o: ^Origin, ds: ^Db_State) {
	req := ds.active
	if req == nil { return }
	m := o.m
	// (a cancelled deletion that is being written stays: its transaction ends it)
	if req.cancelled && req.tx == nil && !req.writing { request_done(ds, req); return }
	if !req.waiting { return }
	// connections that closed need no answer
	for i := len(req.waiting_ack) - 1; i >= 0; i -= 1 {
		if req.waiting_ack[i].closed {
			conn_unref(req.waiting_ack[i])
			ordered_remove(&req.waiting_ack, i)
		}
	}
	if len(req.waiting_ack) > 0 { return }
	if len(ds.conns) > 0 {
		if !req.blocked_sent {
			req.blocked_sent = true
			push_event(req.client, Event{kind = .Blocked, req = req.id, v1 = req.old_version, v2 = req.new_version if req.kind == .Open else 0})
		}
		return
	}
	if req.kind == .Open && !db_resident(o, req.name) { return }   // an upgrade may touch every store: they are read first
	req.waiting = false
	switch req.kind {
	case .Open: begin_upgrade(o, ds, req)
	case .Delete: finish_delete(o, ds, req)
	}
	_ = m
}

@(private)
begin_upgrade :: proc(o: ^Origin, ds: ^Db_State, req: ^Request) {
	m := o.m
	context.allocator = m.allocator
	conn := conn_new(m, req.client, o, ds, req.new_version)
	conn.refs += 1
	req.conn = conn
	tx := tx_new(m, conn, .Version_Change, nil, false)
	tx.upgrade = req
	tx.state = .Active
	req.tx = tx
	// the version (and the database, if it is new) is part of the transaction: an abort takes it back
	op := Op{kind = .Db_Version, db = req.name, version = req.new_version}
	op_encode(&tx.redo, op)
	apply(&o.data, op, &tx.undo)
	tx.x.db = find_db(&o.data, req.name)
	tx.x.changed = true
	push_event(req.client, Event{kind = .Open_Upgrade, req = req.id, conn = conn.id, tx = tx.id, v1 = req.old_version, v2 = req.new_version,
		data = metadata_bytes(m, tx.x.db)})
}

// The upgrade transaction of `req` has ended.
@(private)
upgrade_done :: proc(o: ^Origin, ds: ^Db_State, req: ^Request, committed: bool) {
	m := o.m
	req.tx = nil
	conn := req.conn
	if committed && !req.cancelled && !conn.close_pending && !conn.closed {
		push_event(req.client, Event{kind = .Open_Done, req = req.id, conn = conn.id, v1 = req.new_version, data = metadata_bytes(m, find_db(&o.data, req.name))})
	} else {
		conn.close_pending = true
		conn_try_close(m, conn)
		push_event(req.client, Event{kind = .Open_Error, req = req.id, err = .Aborted})
	}
	request_done(ds, req)
}

////////////////////////////////
// Delete

@(private)
start_delete :: proc(o: ^Origin, ds: ^Db_State, req: ^Request) {
	m := o.m
	db := find_db(&o.data, req.name)
	if db == nil {
		push_event(req.client, Event{kind = .Delete_Done, req = req.id, v1 = 0})
		request_done(ds, req)
		return
	}
	req.old_version = db.version
	send_versionchange(m, ds, req, db.version, 0)
}

@(private)
finish_delete :: proc(o: ^Origin, ds: ^Db_State, req: ^Request) {
	m := o.m
	context.allocator = m.allocator
	tx := tx_new(m, nil, .Version_Change, nil, false)
	tx.ds = ds
	tx.system = req
	req.writing = true
	tx.state = .Active
	tx.client = nil
	op := Op{kind = .Db_Delete, db = req.name}
	op_encode(&tx.redo, op)
	apply(&o.data, op, &tx.undo)
	tx.x.changed = true
	tx_commit_internal(m, tx)
}

////////////////////////////////
// Transactions

@(private)
tx_new :: proc(m: ^Manager, conn: ^Connection, mode: Tx_Mode, scope: []u32, strict: bool) -> ^Tx {
	context.allocator = m.allocator
	tx := new(Tx)
	m.next_id += 1
	tx.id = m.next_id
	tx.conn = conn
	tx.mode = mode
	tx.strict = strict
	tx.scope = make([dynamic]u32)
	append(&tx.scope, ..scope)
	undo_log_init(&tx.undo)
	if conn != nil {
		tx.ds = conn.ds
		tx.client = conn.client
		conn.live_txs += 1
		o := conn.o
		tx.x = Exec{d = &o.data, db = find_db(&o.data, conn.ds.name), undo = &tx.undo, redo = &tx.redo, settings = &m.settings, quota = m.settings.quota_bytes}
		if m.dir != "" && !o.alien { tx.x.values = &tx.values }
		append(&conn.ds.txs, tx)
	}
	m.txs[tx.id] = tx
	return tx
}

@(private)
tx_free :: proc(tx: ^Tx) {
	if tx.x.d != nil { for v in tx.values { delete(v.key, tx.x.d.allocator) } }
	delete(tx.values)
	delete(tx.scope)
	writer_destroy(&tx.redo)
	delete(tx.undo.entries)
	free(tx)
}

@(private)
tx_conflicts :: proc(a, b: ^Tx) -> bool {
	if a.mode == .Read_Only && b.mode == .Read_Only { return false }
	if a.mode == .Version_Change || b.mode == .Version_Change { return true }
	for x in a.scope { for y in b.scope { if x == y { return true } } }
	return false
}

// Starts, in creation order, the pending transactions that no earlier one holds up.
@(private)
schedule :: proc(ds: ^Db_State) {
	for tx, i in ds.txs {
		if tx.state != .Pending { continue }
		blocked := false
		for j in 0 ..< i {
			if ds.txs[j].state != .Finished && tx_conflicts(ds.txs[j], tx) { blocked = true; break }
		}
		if blocked { continue }
		if !tx_stores_ready(ds.o, tx) { continue }   // (a store that is not in memory is being read)
		tx.state = .Active
		push_event(tx.client, Event{kind = .Tx_Started, tx = tx.id})
	}
}

// Creates a transaction on a connection. `scope`: ids of object stores. Pending until the scheduler starts it
// (Tx_Started).
begin_transaction :: proc(c: ^Client, conn_id: u64, scope: []u32, mode: Tx_Mode, strict: bool) -> (id: u64, started: bool, err: Error) {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	conn, ok := m.conns[conn_id]
	if !ok || conn.client != c { return 0, false, .Not_Found }
	if conn.closed || conn.close_pending || mode == .Version_Change { return 0, false, .Invalid_State }
	db := find_db(&conn.o.data, conn.ds.name)
	if db == nil { return 0, false, .Not_Found }
	for s in scope { if find_store(db, s) == nil { return 0, false, .Not_Found } }
	tx := tx_new(m, conn, mode, scope, strict)
	schedule(conn.ds)
	return tx.id, tx.state == .Active, .None
}

// Ends a transaction. Committed: its undo is dropped and the script hears Tx_Complete; otherwise its changes are taken
// back and it hears Tx_Aborted(err). `err` is what the script sees as the reason.
@(private)
tx_finish :: proc(m: ^Manager, tx: ^Tx, committed: bool, err: Error) {
	if tx.state == .Finished { return }
	tx.state = .Finished
	ds := tx.ds
	o := ds.o
	if committed {
		undo_discard(&o.data, &tx.undo)
		m.stats.commits += 1
	} else {
		if tx.stale { undo_discard(&o.data, &tx.undo) } else { undo_rollback(&o.data, &tx.undo) }
		m.stats.rollbacks += 1
	}
	if tx.conn != nil {
		tx.conn.live_txs -= 1
		if tx.client != nil {
			push_event(tx.client, Event{kind = .Tx_Complete if committed else .Tx_Aborted, tx = tx.id, err = err})
		}
	}
	for x, i in ds.txs { if x == tx { ordered_remove(&ds.txs, i); break } }
	delete_key(&m.txs, tx.id)
	conn := tx.conn
	if req := tx.upgrade; req != nil { upgrade_done(o, ds, req, committed) }
	if req := tx.system; req != nil {
		if committed {
			push_event(req.client, Event{kind = .Delete_Done, req = req.id, v1 = req.old_version})
		} else {
			push_event(req.client, Event{kind = .Delete_Error, req = req.id, err = err})
		}
		request_done(ds, req)
	}
	if conn != nil { conn_try_close(m, conn) }
	tx_free(tx)
	schedule(ds)
	db_pump(o, ds)
	maybe_checkpoint(m, o, false)
	maybe_compact(m, o)
}

@(private)
tx_rollback :: proc(m: ^Manager, tx: ^Tx) { tx_finish(m, tx, false, .Aborted) }

// transaction.abort() (and a failed request that nobody handled): back out, tell the script.
tx_abort :: proc(c: ^Client, id: u64, err: Error) -> Error {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	tx, ok := m.txs[id]
	if !ok || tx.client != c { return .Not_Found }
	if tx.state == .Committing || tx.state == .Finished { return .Invalid_State }
	tx_finish(m, tx, false, err)
	return .None
}

// transaction.commit() or the end of the transaction's last request.
tx_commit :: proc(c: ^Client, id: u64) -> Error {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	tx, ok := m.txs[id]
	if !ok || tx.client != c { return .Not_Found }
	if tx.state != .Active { return .Invalid_State }
	tx_commit_internal(m, tx)
	return .None
}

@(private)
tx_commit_internal :: proc(m: ^Manager, tx: ^Tx) {
	context.allocator = m.allocator
	o := tx.ds.o
	if !tx.x.changed || m.dir == "" || o.alien {
		tx_finish(m, tx, true, .None)
		return
	}
	data := make([dynamic]byte, 0, len(tx.redo.data) + FRAME_HEADER + 1)
	frame_payload(&data, tx.redo.data[:])
	tx.state = .Committing
	append(&o.wq, Write_Item{tx = tx, data = data[:], strict = tx.strict})
	request_flush(m, o)
}

////////////////////////////////
// Site data

// Removes everything the origin keeps (Clear site data): connections are closed (the scripts hear "close"), what runs
// is aborted, requests fail, and the journal is emptied.
manager_clear_origin :: proc(m: ^Manager, key: string) {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	context.allocator = m.allocator
	o, loaded := m.origins[key]
	if !loaded {
		// not in memory: only its files go
		if m.dir != "" {
			stem := origin_stem(m, key)
			slash := strings.last_index_byte(stem, '/')
			dir, name := stem[:slash], stem[slash + 1:]
			for n in dir_files_with_prefix(dir, name) {
				rest := n[len(name):]
				_, is_j := generation_of(rest, ".widb")
				_, is_c := generation_of(rest, ".widx")
				if is_j || is_c || strings.has_suffix(rest, ".tmp") { file_delete(strings.concatenate({dir, SEP, n}, context.temp_allocator)) }
			}
		}
		return
	}
	if o.state == .Loading {
		// answered when the load finishes: nothing was opened yet, the files go at once and the load's result is dropped
		o.clear_on_load = true
		return
	}
	for _, ds in o.dbs {
		txs := slice.clone(ds.txs[:], context.temp_allocator)
		for tx in txs {
			if tx.state == .Committing { tx.stale = true } else if tx.state != .Finished { tx_finish(m, tx, false, .Aborted) }
		}
		conns := slice.clone(ds.conns[:], context.temp_allocator)
		for conn in conns {
			push_event(conn.client, Event{kind = .Conn_Closed, conn = conn.id})
			conn.close_pending = true
			conn_try_close(m, conn)
		}
		if req := ds.active; req != nil && req.tx == nil {
			fail_request(o, ds, req, .Aborted)
		}
		for req in ds.queue { push_event(req.client, Event{kind = .Open_Error if req.kind == .Open else .Delete_Error, req = req.id, err = .Aborted}); request_free(req) }
		clear(&ds.queue)
	}
	if m.dir != "" && !o.alien { origin_wipe(m, o) } else { data_destroy(&o.data); data_init(&o.data, m.allocator) }
}