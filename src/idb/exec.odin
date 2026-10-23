package idb

import "core:bytes"
import "core:math"

// What a transaction does to the data of its database, and what it reads from it. The reads are plain functions of the
// data; the changes go through an Exec: each is checked (the specification's constraints), applied with its undo, and
// appended to the redo stream that becomes the journal record when the transaction commits.

Exec :: struct {
	d:        ^Data,
	db:       ^Database,
	undo:     ^Undo_Log,
	redo:     ^Writer,
	settings: ^Settings,
	quota:    i64,
	changed:  bool,    // some op was emitted
	values:   ^[dynamic]Value_Ref,   // the values the transaction put, to find them in the journal once it is written (nil: not tracked)
}

@(private)
emit :: proc(x: ^Exec, op: Op) -> Error {
	o := op
	o.db = x.db.name
	// encoded first: applying may release what the op points into (a record deleted by key)
	mark := len(x.redo.data)
	vp := op_encode(x.redo, o)
	if e := apply(x.d, o, x.undo); e != .None {
		resize(&x.redo.data, mark)
		return e
	}
	x.changed = true
	if o.kind == .Put && x.values != nil && vp >= 0 {
		if s := find_store(x.db, o.store); s != nil {
			if cur, found := ordered_get(&s.records, o.key); found {
				rec := (^Record)(cur)
				if rec.value != nil { append(x.values, Value_Ref{store = o.store, key = clone_bytes(o.key, x.d.allocator), ptr = raw_data(rec.value), rel = vp, len = rec.vlen}) }
			}
		}
	}
	return .None
}

// The next number of the store's key generator as a key, advancing the generator (for a store with a key path, whose
// value gets the key before it is serialized again).
exec_generate_key :: proc(x: ^Exec, store_id: u32, allocator := context.allocator) -> (key: []byte, err: Error) {
	s := find_store(x.db, store_id)
	if s == nil { return nil, .Not_Found }
	if !s.auto_increment { return nil, .Data }
	if s.gen > KEY_GEN_LIMIT { return nil, .Constraint }
	k := key_of_number(s.gen, allocator)
	if e := emit(x, Op{kind = .Key_Gen, store = s.id, gen = s.gen + 1}); e != .None { delete(k, allocator); return nil, e }
	return k, .None
}

////////////////////////////////
// Writes

// Stores a record (IndexedDB "store a record into an object store"). `key` is nil when the script gave none: the
// store's generator makes one. `ikeys`: the entry in each index (the scripts evaluated the key paths). Returns the key
// of the record (valid until the next change).
exec_put :: proc(x: ^Exec, store_id: u32, key: []byte, value: []byte, ikeys: []Index_Key, no_overwrite: bool, from_generator := false) -> (out: []byte, err: Error) {
	s := find_store(x.db, store_id)
	if s == nil { return nil, .Not_Found }
	if len(value) > x.settings.max_value_bytes { return nil, .Too_Large }
	k := key
	generated: []byte
	defer delete(generated, x.d.allocator)
	if k == nil {
		if !s.auto_increment { return nil, .Data }
		if s.gen > KEY_GEN_LIMIT { return nil, .Constraint }
		generated = key_of_number(s.gen, x.d.allocator)
		k = generated
		if e := emit(x, Op{kind = .Key_Gen, store = s.id, gen = s.gen + 1}); e != .None { return nil, e }
	} else {
		if !key_valid(k) { return nil, .Data }
		if len(k) > x.settings.max_key_bytes { return nil, .Too_Large }
		// a key the script took from the generator (peeked before it injected it into the value): the generator moves on
		if from_generator {
			if n, is_num := key_number(k); !is_num || !s.auto_increment || n != s.gen || s.gen > KEY_GEN_LIMIT { return nil, .Data }
			if e := emit(x, Op{kind = .Key_Gen, store = s.id, gen = s.gen + 1}); e != .None { return nil, e }
		} else if n, is_num := key_number(k); is_num && s.auto_increment && n >= s.gen {
			next := math.floor(n) + 1
			if math.floor(n) >= KEY_GEN_LIMIT { next = KEY_GEN_LIMIT * 2 }   // "past 2^53": the next generated key fails
			if e := emit(x, Op{kind = .Key_Gen, store = s.id, gen = next}); e != .None { return nil, e }
		}
	}
	existing, found := ordered_get(&s.records, k)
	if found && no_overwrite { return nil, .Constraint }
	// index keys: well formed, and unique where the index says so
	for ik in ikeys {
		ix := find_index(s, ik.index)
		if ix == nil { return nil, .Not_Found }
		if !key_valid(ik.key) || len(ik.key) > x.settings.max_key_bytes { return nil, .Data }
		if ix.unique && index_has_other(ix, ik.key, k) { return nil, .Constraint }
	}
	// the quota: what the new record adds, less what it replaces
	delta := i64(len(k) + len(value) + RECORD_OVERHEAD)
	for ik in ikeys { delta += i64(len(ik.key) + KEY_OVERHEAD) }
	if found { delta -= record_cost((^Record)(existing)) }
	if delta > 0 && x.d.bytes + delta > x.quota { return nil, .Quota }
	if e := emit(x, Op{kind = .Put, store = s.id, key = k, value = value, ikeys = ikeys}); e != .None { return nil, e }
	cur, _ := ordered_get(&s.records, k)
	return (^Record)(cur).key, .None
}

// Whether the unique index has an entry with this index key that belongs to another record than `pk`.
@(private)
index_has_other :: proc(ix: ^Index, ikey, pk: []byte) -> bool {
	p := ordered_seek(&ix.entries, ikey)
	for pos_valid(&ix.entries, p) {
		k, v := pos_entry(&ix.entries, p)
		if !bytes.has_prefix(k, ikey) { return false }
		rec := (^Record)(v)
		// (the encoding of a binary or string key can be the start of another's: compare the whole index key)
		if bytes.equal(k[:len(k) - len(rec.key)], ikey) && !bytes.equal(rec.key, pk) { return true }
		pos_next(&ix.entries, &p)
	}
	return false
}

// Deletes the records of the store (or, with an index, the records it lists) in the range.
exec_delete_range :: proc(x: ^Exec, store_id: u32, r: Range) -> Error {
	s := find_store(x.db, store_id)
	if s == nil { return .Not_Found }
	src := Source{store = s}
	doomed := make([dynamic][]byte, context.temp_allocator)
	scan(src, r, false, -1, proc(user: rawptr, key, pk: []byte, rec: ^Record) -> bool {
		list := (^[dynamic][]byte)(user)
		append(list, pk)
		return true
	}, &doomed)
	for k in doomed {
		if e := emit(x, Op{kind = .Delete, store = s.id, key = k}); e != .None { return e }
	}
	return .None
}

exec_clear :: proc(x: ^Exec, store_id: u32) -> Error {
	s := find_store(x.db, store_id)
	if s == nil { return .Not_Found }
	if s.records.count == 0 { return .None }
	return emit(x, Op{kind = .Store_Clear, store = s.id})
}

// Index entries for an existing record (populating a new index): unique violations are a ConstraintError.
exec_index_put :: proc(x: ^Exec, store_id, index_id: u32, pk: []byte, ikeys: [][]byte) -> Error {
	s := find_store(x.db, store_id)
	if s == nil { return .Not_Found }
	ix := find_index(s, index_id)
	if ix == nil { return .Not_Found }
	if len(ikeys) == 0 { return .None }
	list := make([]Index_Key, len(ikeys), context.temp_allocator)
	delta: i64
	for k, i in ikeys {
		if !key_valid(k) || len(k) > x.settings.max_key_bytes { return .Data }
		if ix.unique && index_has_other(ix, k, pk) { return .Constraint }
		list[i] = Index_Key{index_id, k}
		delta += i64(len(k) + KEY_OVERHEAD)
	}
	if x.d.bytes + delta > x.quota { return .Quota }
	return emit(x, Op{kind = .Index_Put, store = store_id, key = pk, ikeys = list})
}

// Schema changes (versionchange transactions only; the caller checks).

exec_create_store :: proc(x: ^Exec, name: string, key_path: []byte, auto_increment: bool) -> (id: u32, err: Error) {
	for s in x.db.stores { if s.name == name { return 0, .Constraint } }
	if len(x.db.stores) >= x.settings.max_objects { return 0, .Quota }
	id = x.db.next_store_id
	e := emit(x, Op{kind = .Store_Create, store = id, name = name, key_path = key_path, flags = 1 if auto_increment else 0})
	return id, e
}

exec_delete_store :: proc(x: ^Exec, id: u32) -> Error { return emit(x, Op{kind = .Store_Delete, store = id}) }

exec_rename_store :: proc(x: ^Exec, id: u32, name: string) -> Error {
	for s in x.db.stores { if s.name == name && s.id != id { return .Constraint } }
	return emit(x, Op{kind = .Store_Rename, store = id, name = name})
}

exec_create_index :: proc(x: ^Exec, store_id: u32, name: string, key_path: []byte, unique, multi: bool) -> (id: u32, err: Error) {
	s := find_store(x.db, store_id)
	if s == nil { return 0, .Not_Found }
	for ix in s.indexes { if ix.name == name { return 0, .Constraint } }
	if len(s.indexes) >= x.settings.max_objects { return 0, .Quota }
	id = x.db.next_index_id
	flags: u8 = (1 if unique else 0) | (2 if multi else 0)
	e := emit(x, Op{kind = .Index_Create, store = store_id, index = id, name = name, key_path = key_path, flags = flags})
	return id, e
}

exec_delete_index :: proc(x: ^Exec, store_id, index_id: u32) -> Error {
	return emit(x, Op{kind = .Index_Delete, store = store_id, index = index_id})
}

exec_rename_index :: proc(x: ^Exec, store_id, index_id: u32, name: string) -> Error {
	s := find_store(x.db, store_id)
	if s == nil { return .Not_Found }
	for ix in s.indexes { if ix.name == name && ix.id != index_id { return .Constraint } }
	return emit(x, Op{kind = .Index_Rename, store = store_id, index = index_id, name = name})
}

////////////////////////////////
// Reads

Range :: struct {
	lower, upper:           []byte,
	has_lower, has_upper:   bool,
	lower_open, upper_open: bool,
}

range_has :: proc(r: Range, key: []byte) -> bool {
	if r.has_lower {
		c := bytes.compare(key, r.lower)
		if c < 0 || (c == 0 && r.lower_open) { return false }
	}
	if r.has_upper {
		c := bytes.compare(key, r.upper)
		if c > 0 || (c == 0 && r.upper_open) { return false }
	}
	return true
}

// A store or one of its indexes: what a read walks.
Source :: struct {
	store: ^Store,
	index: ^Index,   // nil: the store's records
}

@(private)
source_entries :: proc(s: Source) -> ^Ordered { return &s.store.records if s.index == nil else &s.index.entries }

// The key an entry is sorted by: the index key (the primary key for the store itself).
@(private)
entry_key :: proc(s: Source, composite: []byte, rec: ^Record) -> []byte {
	if s.index == nil { return rec.key }
	return composite[:len(composite) - len(rec.key)]
}

// The first entry whose key is > `key` (every entry with that key is skipped).
@(private)
seek_after_key :: proc(s: Source, key: []byte) -> Pos {
	o := source_entries(s)
	if s.index == nil { return ordered_seek(o, key, true) }
	tmp := make([]byte, len(key) + 1, context.temp_allocator)
	copy(tmp, key)
	tmp[len(key)] = 0xFF   // above the first byte of any primary key (a tag, 0x50 at most)
	return ordered_seek(o, tmp)
}

@(private)
seek_from_key :: proc(s: Source, key: []byte) -> Pos { return ordered_seek(source_entries(s), key) }

// The last entry before position `p` (ok false when there is none).
@(private)
before :: proc(o: ^Ordered, p: Pos) -> (Pos, bool) {
	q := p
	ok := pos_prev(o, &q)
	return q, ok
}

Direction :: enum u8 { Next, Next_Unique, Prev, Prev_Unique }

// The first entry of the range in the direction.
@(private)
range_start :: proc(s: Source, r: Range, forward: bool) -> (Pos, bool) {
	o := source_entries(s)
	if forward {
		if !r.has_lower { return ordered_first(o), pos_valid(o, ordered_first(o)) }
		p := seek_after_key(s, r.lower) if r.lower_open else seek_from_key(s, r.lower)
		return p, pos_valid(o, p)
	}
	if !r.has_upper { return before(o, ordered_end(o)) }
	if r.upper_open { return before(o, seek_from_key(s, r.upper)) }
	return before(o, seek_after_key(s, r.upper))
}

// Whether the entry at `p` is inside the range (the end of the walk is where it stops being).
@(private)
in_range :: proc(s: Source, r: Range, p: Pos) -> (key, pk: []byte, rec: ^Record, ok: bool) {
	o := source_entries(s)
	if !pos_valid(o, p) { return }
	comp, v := pos_entry(o, p)
	rec = (^Record)(v)
	key = entry_key(s, comp, rec)
	pk = rec.key
	return key, pk, rec, range_has(r, key)
}

Cursor_Request :: struct {
	range:      Range,
	direction:  Direction,
	has_cur:    bool,
	cur_key:    []byte,   // the key of the entry the cursor is on (the index key; the primary key for a store)
	cur_pk:     []byte,
	has_target: bool,     // continue(key)
	target:     []byte,
	has_target_pk: bool,  // continuePrimaryKey(key, primaryKey)
	target_pk:  []byte,
	count:      int,      // advance(count): this many steps (1 for continue)
}

Cursor_Hit :: struct { key, pk: []byte, rec: ^Record }

// One step of a cursor (IndexedDB "iterate a cursor"). Positions are searched again from the keys each time, so a
// cursor stays right when its records change meanwhile.
cursor_step :: proc(s: Source, q: Cursor_Request) -> (hit: Cursor_Hit, found: bool) {
	forward := q.direction == .Next || q.direction == .Next_Unique
	unique := q.direction == .Next_Unique || q.direction == .Prev_Unique
	o := source_entries(s)
	cur_key, cur_pk, have := q.cur_key, q.cur_pk, q.has_cur
	steps := max(q.count, 1)
	for i in 0 ..< steps {
		p: Pos
		ok: bool
		if !have {
			p, ok = range_start(s, q.range, forward)
		} else if forward {
			if unique || s.index == nil {
				p = seek_after_key(s, cur_key)
			} else {
				comp := composite_key(cur_key, cur_pk, context.temp_allocator)
				p = ordered_seek(o, comp, true)
			}
			ok = pos_valid(o, p)
		} else {
			if unique || s.index == nil {
				p, ok = before(o, seek_from_key(s, cur_key))
			} else {
				comp := composite_key(cur_key, cur_pk, context.temp_allocator)
				p, ok = before(o, ordered_seek(o, comp))
			}
		}
		// continue(key) / continuePrimaryKey: no earlier than the target (the first step only)
		if ok && i == 0 && q.has_target {
			if forward {
				tp: Pos
				if q.has_target_pk {
					tp = ordered_seek(o, composite_key(q.target, q.target_pk, context.temp_allocator))
				} else {
					tp = seek_from_key(s, q.target)
				}
				if less_pos(p, tp) { p, ok = tp, pos_valid(o, tp) }
			} else {
				tp: Pos
				tok: bool
				if q.has_target_pk {
					tp, tok = before(o, ordered_seek(o, composite_key(q.target, q.target_pk, context.temp_allocator), true))
				} else {
					tp, tok = before(o, seek_after_key(s, q.target))
				}
				if !tok { ok = false } else if less_pos(tp, p) { p = tp }
			}
		}
		if !ok { return {}, false }
		k, pk, rec, inside := in_range(s, q.range, p)
		if !inside { return {}, false }
		// backwards over distinct keys lands on the last entry of a key: the first one is what the cursor reports
		if !forward && unique && s.index != nil {
			fp := seek_from_key(s, k)
			if fk, fpk, frec, fin := in_range(s, q.range, fp); fin { k, pk, rec = fk, fpk, frec }
		}
		hit = Cursor_Hit{k, pk, rec}
		cur_key, cur_pk, have = k, pk, true
	}
	return hit, true
}

@(private)
less_pos :: proc(a, b: Pos) -> bool { return a.block < b.block || (a.block == b.block && a.index < b.index) }

// Calls `visit` for each entry of the range, forwards or backwards, up to `limit` (< 0: all) until it returns false.
scan :: proc(s: Source, r: Range, backwards: bool, limit: int, visit: proc(user: rawptr, key, pk: []byte, rec: ^Record) -> bool, user: rawptr) {
	o := source_entries(s)
	p, ok := range_start(s, r, !backwards)
	n := 0
	for ok && (limit < 0 || n < limit) {
		k, pk, rec, inside := in_range(s, r, p)
		if !inside { return }
		if !visit(user, k, pk, rec) { return }
		n += 1
		if backwards { ok = pos_prev(o, &p) } else { pos_next(o, &p); ok = pos_valid(o, p) }
	}
}

// The first record of the range (get, getKey): by key for a store, by index key then primary key for an index.
first_in_range :: proc(s: Source, r: Range) -> (hit: Cursor_Hit, found: bool) {
	return cursor_step(s, Cursor_Request{range = r, direction = .Next})
}

count_range :: proc(s: Source, r: Range) -> (n: int) {
	if !r.has_lower && !r.has_upper { return source_entries(s).count }
	scan(s, r, false, -1, proc(user: rawptr, key, pk: []byte, rec: ^Record) -> bool { (^int)(user)^ += 1; return true }, &n)
	return
}
