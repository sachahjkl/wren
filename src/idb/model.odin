package idb

import "base:runtime"
import "core:bytes"

// The data of one origin: its databases, object stores, records and indexes, in memory. Every change is an Op: the
// same value is applied to the data (apply), written to the journal (op_encode) and read back when the journal is
// replayed (op_decode). apply can record how to take a change back (Undo_Log): a transaction applies its changes at once
// (it is the only one that may touch what it changes) and rolls them back if it aborts.
//
// Identity: databases by name; object stores and indexes by ids that are never reused in a database (a rename does not
// change them). Key paths are opaque bytes here (the scripts' side evaluates them). Keys are encoded keys (key.odin).

Error :: enum u8 {
	None,
	Constraint,       // a key that exists (add), a unique index violated, a key generator past its limit
	Quota,
	Read_Only,        // a change in a read-only transaction
	Not_Found,        // no such database, object store, index
	Invalid_State,    // the transaction is finished, the store is not in its scope, a change outside a versionchange
	Data,             // an encoded key that is not a key, a malformed message
	Version,          // an open for a version lower than the database's
	Aborted,
	Too_Large,        // a value or key over the limit
	Io,               // the file could not be written
	Unknown,
}

RECORD_OVERHEAD :: 64   // what a record is counted besides its bytes (headers, pointers)
KEY_OVERHEAD    :: 24   // ... one index entry

Index_Key :: struct { index: u32, key: []byte }

// A record. Its value is not always in memory: once its transaction is on the disk it is only where the journal has it (off,
// in the file of generation gen) and is read when asked for, with the most recently used ones kept (values.odin). The keys,
// and the index keys, always are.
Record :: struct {
	key:      []byte,
	ikeys:    [dynamic]Index_Key,   // the entry of this record in each index (a multi-entry index may have several)
	value:    []byte,               // in memory: not written yet, or kept in the cache; nil: on the disk only
	voff:     i64,                  // offset of the value in the journal file of generation gen; < 0: nowhere yet
	vlen:     u32,
	gen:      u8,
	cached:   bool,                 // linked in Data's list of cached values
	lru_prev, lru_next: ^Record,
}

Index :: struct {
	id:       u32,
	name:     string,
	key_path: []byte,   // opaque
	unique:   bool,
	multi:    bool,
	entries:  Ordered,  // index key + primary key -> ^Record
}

Store :: struct {
	id:             u32,
	name:           string,
	key_path:       []byte,   // opaque
	auto_increment: bool,
	gen:            f64,      // the key generator's current number (1 at the start)
	records:        Ordered,  // primary key -> ^Record (the keys are the records' own)
	indexes:        [dynamic]^Index,
	bytes:          i64,      // what its records count against the quota
	// Residency (checkpoint.odin): a store read from a checkpoint is not in memory until a transaction needs it.
	resident:       bool,     // records and index entries are in memory
	loading:        bool,     // being read
	has_section:    bool,     // the checkpoint has its records: section
	section:        Section,
	ck_rev:         u32,      // ev of the data its checkpoint section holds: unchanged since (rev == ck_rev) means clean, and it can be dropped from memory
	rev:            u32,      // bumped by every change of its data
	used_ms:        f64,      // when a transaction last used it
}

Database :: struct {
	name:           string,
	version:        u64,
	stores:         [dynamic]^Store,
	next_store_id:  u32,
	next_index_id:  u32,
}

Data :: struct {
	dbs:       [dynamic]^Database,
	bytes:     i64,                // the sum of the stores' bytes
	allocator: runtime.Allocator,
	vsrc:      ^Value_Source,      // where values are read from (nil: memory only, every value stays in memory)
	replay_base: i64,              // while replaying a journal without keeping its values: the file offset of the ops being read (else < 0)
	replay_gen:  u8,
	lru_head, lru_tail: ^Record,   // the cached values, most recently used first
	cache_bytes: i64,
	cache_limit: i64,
}

KEY_GEN_LIMIT :: f64(1 << 53)

data_init :: proc(d: ^Data, allocator: runtime.Allocator) {
	d^ = {allocator = allocator, replay_base = -1, cache_limit = 64 << 20}
	d.dbs = make([dynamic]^Database, allocator)
}

data_destroy :: proc(d: ^Data) {
	context.allocator = d.allocator
	for db in d.dbs { database_free(d, db) }
	delete(d.dbs)
	d^ = {}
}

@(private)
clone_bytes :: proc(b: []byte, allocator: runtime.Allocator) -> []byte {
	if len(b) == 0 { return nil }
	out := make([]byte, len(b), allocator)
	copy(out, b)
	return out
}

@(private)
clone_str :: proc(s: string, allocator: runtime.Allocator) -> string { return string(clone_bytes(transmute([]byte)s, allocator)) }

record_cost :: proc(r: ^Record) -> i64 {
	n := i64(len(r.key) + int(r.vlen) + RECORD_OVERHEAD)
	for k in r.ikeys { n += i64(len(k.key) + KEY_OVERHEAD) }
	return n
}

@(private)
record_free :: proc(d: ^Data, r: ^Record) {
	if r.cached { cache_unlink(d, r) }
	delete(r.key, d.allocator)
	delete(r.value, d.allocator)
	for k in r.ikeys { delete(k.key, d.allocator) }
	delete(r.ikeys)
	free(r, d.allocator)
}

@(private)
index_free :: proc(d: ^Data, ix: ^Index) {
	delete(ix.name, d.allocator)
	delete(ix.key_path, d.allocator)
	ordered_destroy(&ix.entries)
	free(ix, d.allocator)
}

@(private)
store_free :: proc(d: ^Data, s: ^Store) {
	it := ordered_first(&s.records)
	for pos_valid(&s.records, it) {
		_, v := pos_entry(&s.records, it)
		record_free(d, (^Record)(v))
		pos_next(&s.records, &it)
	}
	ordered_destroy(&s.records)
	for ix in s.indexes { index_free(d, ix) }
	delete(s.indexes)
	delete(s.name, d.allocator)
	delete(s.key_path, d.allocator)
	free(s, d.allocator)
}

@(private)
database_free :: proc(d: ^Data, db: ^Database) {
	for s in db.stores { store_free(d, s) }
	delete(db.stores)
	delete(db.name, d.allocator)
	free(db, d.allocator)
}

find_db :: proc(d: ^Data, name: string) -> ^Database {
	for db in d.dbs { if db.name == name { return db } }
	return nil
}

find_store :: proc(db: ^Database, id: u32) -> ^Store {
	for s in db.stores { if s.id == id { return s } }
	return nil
}

find_index :: proc(s: ^Store, id: u32) -> ^Index {
	for ix in s.indexes { if ix.id == id { return ix } }
	return nil
}

////////////////////////////////
// Ops

Op_Kind :: enum u8 {
	None,
	Db_Version,     // db, version: sets the version, creating the database
	Db_Delete,      // db
	Store_Create,   // db, store (id), name, key_path, flags (1 = auto increment)
	Store_Delete,   // db, store
	Store_Rename,   // db, store, name
	Store_Clear,    // db, store
	Index_Create,   // db, store, index (id), name, key_path, flags (1 = unique, 2 = multi entry)
	Index_Delete,   // db, store, index
	Index_Rename,   // db, store, index, name
	Put,            // db, store, key, value, ikeys: the record at `key` becomes this, with these index entries
	Delete,         // db, store, key
	Index_Put,      // db, store, key, ikeys: index entries added to the existing record at `key`
	Key_Gen,        // db, store, gen: the key generator's current number becomes `gen`
}

Op :: struct {
	kind:     Op_Kind,
	db:       string,
	store:    u32,
	index:    u32,
	name:     string,
	key_path: []byte,
	flags:    u8,
	version:  u64,
	key:      []byte,
	value:    []byte,
	ikeys:    []Index_Key,
	gen:      f64,
	value_pos: int,   // decoded ops: where the value is in the reader's data
}

Writer :: struct { data: [dynamic]byte }

writer_destroy :: proc(w: ^Writer) { delete(w.data) }

w_u8 :: proc(w: ^Writer, v: u8) { append(&w.data, v) }

w_uv :: proc(w: ^Writer, v: u64) {
	x := v
	for x >= 0x80 { append(&w.data, byte(x) | 0x80); x >>= 7 }
	append(&w.data, byte(x))
}

w_bytes :: proc(w: ^Writer, b: []byte) { w_uv(w, u64(len(b))); append(&w.data, ..b) }
w_str :: proc(w: ^Writer, s: string) { w_bytes(w, transmute([]byte)s) }
w_f64 :: proc(w: ^Writer, v: f64) { u := transmute(u64)v; for i in 0 ..< 8 { append(&w.data, byte(u >> (uint(i) * 8))) } }

Reader :: struct {
	data: []byte,
	pos:  int,
	bad:  bool,
}

r_u8 :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.data) { r.bad = true; return 0 }
	v := r.data[r.pos]
	r.pos += 1
	return v
}

r_uv :: proc(r: ^Reader) -> u64 {
	v: u64
	shift: uint
	for {
		if r.pos >= len(r.data) || shift > 63 { r.bad = true; return 0 }
		b := r.data[r.pos]
		r.pos += 1
		v |= u64(b & 0x7F) << shift
		if b & 0x80 == 0 { return v }
		shift += 7
	}
}

// The bytes in place (not a copy).
r_bytes :: proc(r: ^Reader) -> []byte {
	n := r_uv(r)
	if r.bad || n > u64(len(r.data) - r.pos) { r.bad = true; return nil }
	b := r.data[r.pos:][:n]
	r.pos += int(n)
	return b
}

r_str :: proc(r: ^Reader) -> string { return string(r_bytes(r)) }

r_f64 :: proc(r: ^Reader) -> f64 {
	if r.pos + 8 > len(r.data) { r.bad = true; return 0 }
	u: u64
	for i in 0 ..< 8 { u |= u64(r.data[r.pos + i]) << (uint(i) * 8) }
	r.pos += 8
	return transmute(f64)u
}

// Returns where the value of a Put begins in w.data (-1: no value), for the place of the value in the journal.
op_encode :: proc(w: ^Writer, op: Op) -> (value_pos: int) {
	value_pos = -1
	w_u8(w, u8(op.kind))
	w_str(w, op.db)
	switch op.kind {
	case .None:
	case .Db_Version: w_uv(w, op.version)
	case .Db_Delete:
	case .Store_Create: w_uv(w, u64(op.store)); w_str(w, op.name); w_bytes(w, op.key_path); w_u8(w, op.flags)
	case .Store_Delete, .Store_Clear: w_uv(w, u64(op.store))
	case .Store_Rename: w_uv(w, u64(op.store)); w_str(w, op.name)
	case .Index_Create: w_uv(w, u64(op.store)); w_uv(w, u64(op.index)); w_str(w, op.name); w_bytes(w, op.key_path); w_u8(w, op.flags)
	case .Index_Delete: w_uv(w, u64(op.store)); w_uv(w, u64(op.index))
	case .Index_Rename: w_uv(w, u64(op.store)); w_uv(w, u64(op.index)); w_str(w, op.name)
	case .Put:
		w_uv(w, u64(op.store)); w_bytes(w, op.key)
		w_uv(w, u64(len(op.value)))
		value_pos = len(w.data)
		append(&w.data, ..op.value)
		w_uv(w, u64(len(op.ikeys)))
		for k in op.ikeys { w_uv(w, u64(k.index)); w_bytes(w, k.key) }
	case .Delete: w_uv(w, u64(op.store)); w_bytes(w, op.key)
	case .Index_Put:
		w_uv(w, u64(op.store)); w_bytes(w, op.key)
		w_uv(w, u64(len(op.ikeys)))
		for k in op.ikeys { w_uv(w, u64(k.index)); w_bytes(w, k.key) }
	case .Key_Gen: w_uv(w, u64(op.store)); w_f64(w, op.gen)
	}
	return
}

// Reads one op; its strings and bytes point into the reader's data. `ikeys` is allocated with `allocator`.
op_decode :: proc(r: ^Reader, allocator: runtime.Allocator) -> (op: Op, ok: bool) {
	k := r_u8(r)
	if r.bad || k == 0 || k > u8(max(Op_Kind)) { return {}, false }
	op.kind = Op_Kind(k)
	op.db = r_str(r)
	read_ikeys :: proc(r: ^Reader, allocator: runtime.Allocator) -> []Index_Key {
		n := r_uv(r)
		if r.bad || n > u64(len(r.data) - r.pos) { r.bad = true; return nil }
		out := make([]Index_Key, int(n), allocator)
		for i in 0 ..< int(n) {
			out[i].index = u32(r_uv(r))
			out[i].key = r_bytes(r)
		}
		return out
	}
	switch op.kind {
	case .None:
	case .Db_Version: op.version = r_uv(r)
	case .Db_Delete:
	case .Store_Create: op.store = u32(r_uv(r)); op.name = r_str(r); op.key_path = r_bytes(r); op.flags = r_u8(r)
	case .Store_Delete, .Store_Clear: op.store = u32(r_uv(r))
	case .Store_Rename: op.store = u32(r_uv(r)); op.name = r_str(r)
	case .Index_Create: op.store = u32(r_uv(r)); op.index = u32(r_uv(r)); op.name = r_str(r); op.key_path = r_bytes(r); op.flags = r_u8(r)
	case .Index_Delete: op.store = u32(r_uv(r)); op.index = u32(r_uv(r))
	case .Index_Rename: op.store = u32(r_uv(r)); op.index = u32(r_uv(r)); op.name = r_str(r)
	case .Put:
		op.store = u32(r_uv(r)); op.key = r_bytes(r)
		vl := r_uv(r)
		if r.bad || vl > u64(len(r.data) - r.pos) { r.bad = true } else {
			op.value_pos = r.pos
			op.value = r.data[r.pos:][:vl]
			r.pos += int(vl)
		}
		op.ikeys = read_ikeys(r, allocator)
	case .Delete: op.store = u32(r_uv(r)); op.key = r_bytes(r)
	case .Index_Put: op.store = u32(r_uv(r)); op.key = r_bytes(r); op.ikeys = read_ikeys(r, allocator)
	case .Key_Gen: op.store = u32(r_uv(r)); op.gen = r_f64(r)
	}
	if r.bad {
		delete(op.ikeys, allocator)
		return {}, false
	}
	return op, true
}

////////////////////////////////
// Undo

Undo_Record :: struct { db: ^Database, store: ^Store, key: []byte, old: ^Record }   // key: a copy
Undo_Version :: struct { db: ^Database, old: u64 }
Undo_Db_Created :: struct { db: ^Database }
Undo_Store_Created :: struct { db: ^Database, store: ^Store, next_store_id: u32 }
Undo_Store_Deleted :: struct { db: ^Database, store: ^Store, at: int }
Undo_Store_Renamed :: struct { store: ^Store, old: string }
Undo_Cleared :: struct { db: ^Database, store: ^Store, records: Ordered, indexes: [dynamic]Undo_Cleared_Index, bytes: i64 }
Undo_Cleared_Index :: struct { index: ^Index, entries: Ordered }
Undo_Index_Created :: struct { store: ^Store, index: ^Index, next_index_id: u32, db: ^Database }
Undo_Index_Deleted :: struct { store: ^Store, index: ^Index, at: int }
Undo_Index_Renamed :: struct { index: ^Index, old: string }
Undo_Index_Put :: struct { store: ^Store, record: ^Record, index: u32, key: []byte }   // key: the index key added
Undo_Gen :: struct { store: ^Store, old: f64 }
Undo_Db_Deleted :: struct { db: ^Database, at: int, bytes: i64 }

Undo :: union {
	Undo_Record, Undo_Version, Undo_Db_Created, Undo_Store_Created, Undo_Store_Deleted, Undo_Store_Renamed, Undo_Cleared,
	Undo_Index_Created, Undo_Index_Deleted, Undo_Index_Renamed, Undo_Index_Put, Undo_Gen, Undo_Db_Deleted,
}

Undo_Log :: struct { entries: [dynamic]Undo }

undo_log_init :: proc(u: ^Undo_Log) { u.entries = make([dynamic]Undo, base_allocator()) }

// The changes are kept: what the log held back (replaced records, deleted stores) is freed.
undo_discard :: proc(d: ^Data, u: ^Undo_Log) {
	context.allocator = d.allocator
	for e in u.entries {
		switch v in e {
		case Undo_Record: delete(v.key); if v.old != nil { record_free(d, v.old) }
		case Undo_Version, Undo_Db_Created, Undo_Store_Created, Undo_Index_Created, Undo_Gen:
		case Undo_Store_Renamed: delete(v.old, d.allocator)
		case Undo_Index_Renamed: delete(v.old, d.allocator)
		case Undo_Store_Deleted: store_free(d, v.store)
		case Undo_Db_Deleted: database_free(d, v.db)
		case Undo_Cleared:
			x := v
			it := ordered_first(&x.records)
			for pos_valid(&x.records, it) {
				_, val := pos_entry(&x.records, it)
				record_free(d, (^Record)(val))
				pos_next(&x.records, &it)
			}
			ordered_destroy(&x.records)
			for &ci in x.indexes { ordered_destroy(&ci.entries) }
			delete(x.indexes)
		case Undo_Index_Deleted: index_free(d, v.index)
		case Undo_Index_Put: delete(v.key)
		}
	}
	delete(u.entries)
	u.entries = {}
}

// The changes are taken back, newest first; with 	o, only those after that many entries (what one request did).
undo_rollback :: proc(d: ^Data, u: ^Undo_Log, to := 0) {
	context.allocator = d.allocator
	#reverse for e in u.entries[to:] {
		switch v in e {
		case Undo_Record:
			if cur, found := ordered_get(&v.store.records, v.key); found {
				drop_record(d, v.store, (^Record)(cur))
				record_free(d, (^Record)(cur))
			}
			if v.old != nil { insert_record(d, v.store, v.old) }
			delete(v.key)
		case Undo_Version: v.db.version = v.old
		case Undo_Db_Created:
			for db, i in d.dbs { if db == v.db { ordered_remove(&d.dbs, i); break } }
			d.bytes -= db_bytes(v.db)
			database_free(d, v.db)
		case Undo_Store_Created:
			for s, i in v.db.stores { if s == v.store { ordered_remove(&v.db.stores, i); break } }
			d.bytes -= v.store.bytes
			store_free(d, v.store)
			v.db.next_store_id = v.next_store_id
		case Undo_Store_Deleted:
			inject_at(&v.db.stores, v.at, v.store)
			d.bytes += v.store.bytes
		case Undo_Store_Renamed:
			delete(v.store.name, d.allocator)
			v.store.name = v.old
		case Undo_Cleared:
			x := v
			// whatever is in the store now was put after the clear and has been taken back already: it is empty
			ordered_destroy(&x.store.records)
			x.store.records = x.records
			for ci in x.indexes {
				ordered_destroy(&ci.index.entries)
				ci.index.entries = ci.entries
			}
			delete(x.indexes)
			x.store.bytes = x.bytes
			d.bytes += x.bytes
		case Undo_Index_Created:
			for ix, i in v.store.indexes { if ix == v.index { ordered_remove(&v.store.indexes, i); break } }
			index_free(d, v.index)
			v.db.next_index_id = v.next_index_id
		case Undo_Index_Deleted:
			inject_at(&v.store.indexes, v.at, v.index)
			it := ordered_first(&v.index.entries)
			for pos_valid(&v.index.entries, it) {
				k, val := pos_entry(&v.index.entries, it)
				rec := (^Record)(val)
				ik := k[:len(k) - len(rec.key)]
				append(&rec.ikeys, Index_Key{v.index.id, clone_bytes(ik, d.allocator)})
				d.bytes += i64(len(ik) + KEY_OVERHEAD)
				v.store.bytes += i64(len(ik) + KEY_OVERHEAD)
				pos_next(&v.index.entries, &it)
			}
		case Undo_Index_Renamed:
			delete(v.index.name, d.allocator)
			v.index.name = v.old
		case Undo_Index_Put:
			ix := find_index(v.store, v.index)
			if ix != nil {
				ck := composite_key(v.key, v.record.key, context.temp_allocator)
				ordered_delete(&ix.entries, ck)
			}
			for k, i in v.record.ikeys {
				if k.index == v.index && bytes.equal(k.key, v.key) {
					delete(k.key, d.allocator)
					unordered_remove(&v.record.ikeys, i)
					break
				}
			}
			d.bytes -= i64(len(v.key) + KEY_OVERHEAD)
			v.store.bytes -= i64(len(v.key) + KEY_OVERHEAD)
			delete(v.key)
		case Undo_Gen: v.store.gen = v.old
		case Undo_Db_Deleted:
			inject_at(&d.dbs, v.at, v.db)
			d.bytes += v.bytes
		}
	}
	if to > 0 {
		resize(&u.entries, to)
		return
	}
	delete(u.entries)
	u.entries = {}
}

@(private)
base_allocator :: proc() -> runtime.Allocator { return context.allocator }

db_bytes :: proc(db: ^Database) -> i64 {
	n: i64
	for s in db.stores { n += s.bytes }
	return n
}

composite_key :: proc(ikey, pk: []byte, allocator: runtime.Allocator) -> []byte {
	out := make([]byte, len(ikey) + len(pk), allocator)
	copy(out, ikey)
	copy(out[len(ikey):], pk)
	return out
}

// Removes `r` from the store's records and its index entries (not freed).
@(private)
drop_record :: proc(d: ^Data, s: ^Store, r: ^Record) {
	for k in r.ikeys {
		if ix := find_index(s, k.index); ix != nil {
			ordered_delete(&ix.entries, composite_key(k.key, r.key, context.temp_allocator))
		}
	}
	ordered_delete(&s.records, r.key)
	s.rev += 1
	c := record_cost(r)
	s.bytes -= c
	d.bytes -= c
}

// Adds `r` (key, ikeys filled) to the store's records and index entries.
@(private)
insert_record :: proc(d: ^Data, s: ^Store, r: ^Record) {
	ordered_put(&s.records, r.key, r)
	s.rev += 1
	for k in r.ikeys {
		if ix := find_index(s, k.index); ix != nil {
			ordered_put(&ix.entries, composite_key(k.key, r.key, context.temp_allocator), r)
		}
	}
	c := record_cost(r)
	s.bytes += c
	d.bytes += c
}

////////////////////////////////
// Apply

// Applies `op` to the data. `undo` (nil when replaying a journal) receives how to take it back. Only structural
// problems fail (a store that does not exist): the checks the specification asks for (a key that exists, a unique
// index) belong to the caller, which knows what it is asking for.
apply :: proc(d: ^Data, op: Op, undo: ^Undo_Log) -> Error {
	context.allocator = d.allocator
	push :: proc(u: ^Undo_Log, e: Undo) { if u != nil { append(&u.entries, e) } }
	db: ^Database
	if op.kind != .Db_Version {
		db = find_db(d, op.db)
		if db == nil { return .Not_Found }
	}
	switch op.kind {
	case .None: return .Data
	case .Db_Version:
		db = find_db(d, op.db)
		if db == nil {
			db = new(Database)
			db.name = clone_str(op.db, d.allocator)
			db.stores = make([dynamic]^Store)
			db.next_store_id = 1
			db.next_index_id = 1
			append(&d.dbs, db)
			push(undo, Undo_Db_Created{db})
			db.version = op.version
			return .None
		}
		push(undo, Undo_Version{db, db.version})
		db.version = op.version
	case .Db_Delete:
		for x, i in d.dbs {
			if x == db {
				ordered_remove(&d.dbs, i)
				b := db_bytes(db)
				d.bytes -= b
				if undo != nil { push(undo, Undo_Db_Deleted{db, i, b}) } else { database_free(d, db) }
				break
			}
		}
	case .Store_Create:
		if find_store(db, op.store) != nil { return .Constraint }
		s := new(Store)
		s.id = op.store
		s.name = clone_str(op.name, d.allocator)
		s.key_path = clone_bytes(op.key_path, d.allocator)
		s.auto_increment = op.flags & 1 != 0
		s.gen = 1
		s.resident = true
		ordered_init(&s.records, d.allocator, true)
		s.indexes = make([dynamic]^Index)
		old_next := db.next_store_id
		append(&db.stores, s)
		if op.store >= db.next_store_id { db.next_store_id = op.store + 1 }
		push(undo, Undo_Store_Created{db, s, old_next})
	case .Store_Delete:
		for s, i in db.stores {
			if s.id == op.store {
				ordered_remove(&db.stores, i)
				d.bytes -= s.bytes
				if undo != nil { push(undo, Undo_Store_Deleted{db, s, i}) } else { store_free(d, s) }
				return .None
			}
		}
		return .Not_Found
	case .Store_Rename:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		old := s.name
		s.name = clone_str(op.name, d.allocator)
		if undo != nil { push(undo, Undo_Store_Renamed{s, old}) } else { delete(old, d.allocator) }
	case .Store_Clear:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		s.rev += 1
		if undo == nil {
			clear_store(d, s)
		} else {
			c := Undo_Cleared{db = db, store = s, records = s.records, bytes = s.bytes}
			c.indexes = make([dynamic]Undo_Cleared_Index)
			ordered_init(&s.records, d.allocator, true)
			for ix in s.indexes {
				append(&c.indexes, Undo_Cleared_Index{ix, ix.entries})
				ordered_init(&ix.entries, d.allocator)
			}
			d.bytes -= s.bytes
			s.bytes = 0
			push(undo, c)
		}
	case .Index_Create:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		if find_index(s, op.index) != nil { return .Constraint }
		ix := new(Index)
		ix.id = op.index
		ix.name = clone_str(op.name, d.allocator)
		ix.key_path = clone_bytes(op.key_path, d.allocator)
		ix.unique = op.flags & 1 != 0
		ix.multi = op.flags & 2 != 0
		ordered_init(&ix.entries, d.allocator)
		old_next := db.next_index_id
		append(&s.indexes, ix)
		if op.index >= db.next_index_id { db.next_index_id = op.index + 1 }
		push(undo, Undo_Index_Created{s, ix, old_next, db})
	case .Index_Delete:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		for ix, i in s.indexes {
			if ix.id != op.index { continue }
			ordered_remove(&s.indexes, i)
			// the records forget their entries in it
			it := ordered_first(&ix.entries)
			for pos_valid(&ix.entries, it) {
				k, val := pos_entry(&ix.entries, it)
				rec := (^Record)(val)
				ik := k[:len(k) - len(rec.key)]
				for rk, j in rec.ikeys {
					if rk.index == ix.id && bytes.equal(rk.key, ik) {
						delete(rk.key, d.allocator)
						unordered_remove(&rec.ikeys, j)
						break
					}
				}
				c := i64(len(ik) + KEY_OVERHEAD)
				s.bytes -= c
				d.bytes -= c
				pos_next(&ix.entries, &it)
			}
			if undo != nil { push(undo, Undo_Index_Deleted{s, ix, i}) } else { index_free(d, ix) }
			return .None
		}
		return .Not_Found
	case .Index_Rename:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		ix := find_index(s, op.index)
		if ix == nil { return .Not_Found }
		old := ix.name
		ix.name = clone_str(op.name, d.allocator)
		if undo != nil { push(undo, Undo_Index_Renamed{ix, old}) } else { delete(old, d.allocator) }
	case .Put:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		r := new(Record)
		r.key = clone_bytes(op.key, d.allocator)
		if d.replay_base >= 0 {
			// replaying a journal that stays on the disk: the value is where it was read, not kept
			r.voff, r.gen = d.replay_base + i64(op.value_pos), d.replay_gen
		} else {
			r.value = clone_bytes(op.value, d.allocator)
			r.voff = -1
		}
		r.vlen = u32(len(op.value))
		r.ikeys = make([dynamic]Index_Key, 0, len(op.ikeys))
		// (the keys of an index that is gone are dropped: a record read back sees the schema as it ended)
		for k in op.ikeys { if find_index(s, k.index) != nil { append(&r.ikeys, Index_Key{k.index, clone_bytes(k.key, d.allocator)}) } }
		var_old: ^Record
		if cur, found := ordered_get(&s.records, op.key); found {
			var_old = (^Record)(cur)
			drop_record(d, s, var_old)
		}
		insert_record(d, s, r)
		if undo != nil {
			push(undo, Undo_Record{db, s, clone_bytes(op.key, d.allocator), var_old})
		} else if var_old != nil {
			record_free(d, var_old)
		}
	case .Delete:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		cur, found := ordered_get(&s.records, op.key)
		if !found { return .None }
		rec := (^Record)(cur)
		drop_record(d, s, rec)
		if undo != nil { push(undo, Undo_Record{db, s, clone_bytes(op.key, d.allocator), rec}) } else { record_free(d, rec) }
	case .Index_Put:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		cur, found := ordered_get(&s.records, op.key)
		if !found { return .Not_Found }
		rec := (^Record)(cur)
		for k in op.ikeys {
			ix := find_index(s, k.index)
			if ix == nil { return .Not_Found }
			dup := false
			for e in rec.ikeys { if e.index == k.index && bytes.equal(e.key, k.key) { dup = true; break } }
			if dup { continue }
			kc := clone_bytes(k.key, d.allocator)
			append(&rec.ikeys, Index_Key{k.index, kc})
			ordered_put(&ix.entries, composite_key(k.key, rec.key, context.temp_allocator), rec)
			c := i64(len(k.key) + KEY_OVERHEAD)
			s.bytes += c
			d.bytes += c
			if undo != nil { push(undo, Undo_Index_Put{s, rec, k.index, clone_bytes(k.key, d.allocator)}) }
		}
	case .Key_Gen:
		s := find_store(db, op.store)
		if s == nil { return .Not_Found }
		push(undo, Undo_Gen{s, s.gen})
		s.gen = op.gen
	}
	return .None
}

@(private)
clear_store :: proc(d: ^Data, s: ^Store) {
	it := ordered_first(&s.records)
	for pos_valid(&s.records, it) {
		_, v := pos_entry(&s.records, it)
		record_free(d, (^Record)(v))
		pos_next(&s.records, &it)
	}
	ordered_clear(&s.records)
	for ix in s.indexes { ordered_clear(&ix.entries) }
	d.bytes -= s.bytes
	s.bytes = 0
}

////////////////////////////////
// Snapshots: the ops that rebuild the data (journal compaction)

// Appends to `out` the encoded ops that recreate `d`, as records of about `chunk` bytes each.
snapshot_ops :: proc(d: ^Data, chunk: int, emit: proc(user: rawptr, payload: []byte), user: rawptr) {
	w: Writer
	defer writer_destroy(&w)
	flush :: proc(w: ^Writer, emit: proc(user: rawptr, payload: []byte), user: rawptr) {
		if len(w.data) > 0 { emit(user, w.data[:]); clear(&w.data) }
	}
	for db in d.dbs {
		op_encode(&w, Op{kind = .Db_Version, db = db.name, version = db.version})
		// ids are kept as they are; the counters are raised by a store or index created with the highest id
		for s in db.stores {
			flags: u8 = 1 if s.auto_increment else 0
			op_encode(&w, Op{kind = .Store_Create, db = db.name, store = s.id, name = s.name, key_path = s.key_path, flags = flags})
			for ix in s.indexes {
				f: u8 = (1 if ix.unique else 0) | (2 if ix.multi else 0)
				op_encode(&w, Op{kind = .Index_Create, db = db.name, store = s.id, index = ix.id, name = ix.name, key_path = ix.key_path, flags = f})
			}
			op_encode(&w, Op{kind = .Key_Gen, db = db.name, store = s.id, gen = s.gen})
			it := ordered_first(&s.records)
			for pos_valid(&s.records, it) {
				_, v := pos_entry(&s.records, it)
				r := (^Record)(v)
				val, _ := rec_value(d, r)
				op_encode(&w, Op{kind = .Put, db = db.name, store = s.id, key = r.key, value = val, ikeys = r.ikeys[:]})
				if len(w.data) >= chunk { flush(&w, emit, user) }
				pos_next(&s.records, &it)
			}
		}
		// the id counters (ids of stores and indexes deleted since are never reused)
		flush(&w, emit, user)
	}
	flush(&w, emit, user)
}
