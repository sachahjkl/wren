package idb

import "core:sync"

// The requests of a transaction, as the scripts' side sends them (native/js/prelude/idb.js builds these bytes) and the
// manager executes them. A request is an operation code and its arguments in the encoding of model.odin (LEB128
// integers, length-prefixed byte strings); the reply, written by the operation, depends on the operation.
//
//   range     flags (1 lower, 2 upper, 4 lower open, 8 upper open), then the bounds present
//   GET       store, index (0: the store), range, key only        -> found; primary key; value (not for key only)
//   COUNT     store, index, range                                  -> count
//   GET_ALL   store, index, range, mode (1 keys, 2 values, 3 key, primary key and value), flags (1 backwards,
//             2 one record per key), limit (0: all)                -> count; per entry what the mode says
//   CURSOR    store, index, range, direction (0 next, 1 next unique, 2 prev, 3 prev unique), has current, key, primary
//             key, has target, target, has target primary key, target primary key, count, key only
//                                                                  -> found; key; primary key; value (not for key only)
//   PUT       store, flags (1 no overwrite, 2 has key, 4 the key is the generator's: it moves on), key (if), value, count,
//             then (index, key) each                               -> key
//   GEN_KEY   store                                                -> key (and the generator moves on)
//   PEEK_KEY  store                                                -> the generator's next key (it does not move)
//   A request that fails takes back everything it did, the generator's move included.
//   DELETE    store, range
//   CLEAR     store
//   INDEX_PUT store, index, primary key, count, then the keys
//   CREATE_STORE name, key path, flags (1 auto increment)          -> id
//   DELETE_STORE store;  RENAME_STORE store, name
//   CREATE_INDEX store, name, key path, flags (1 unique, 2 multi entry) -> id
//   DELETE_INDEX store, index;  RENAME_INDEX store, index, name

Request_Op :: enum u8 {
	None,
	Get, Count, Get_All, Cursor, Put, Gen_Key, Delete, Clear, Index_Put,
	Create_Store, Delete_Store, Rename_Store, Create_Index, Delete_Index, Rename_Index, Peek_Key,
}

@(private)
r_range :: proc(r: ^Reader) -> Range {
	flags := r_u8(r)
	out: Range
	if flags & 1 != 0 { out.has_lower = true; out.lower = r_bytes(r) }
	if flags & 2 != 0 { out.has_upper = true; out.upper = r_bytes(r) }
	out.lower_open = flags & 4 != 0
	out.upper_open = flags & 8 != 0
	if out.has_lower && !key_valid(out.lower) { r.bad = true }
	if out.has_upper && !key_valid(out.upper) { r.bad = true }
	return out
}

@(private)
in_scope :: proc(tx: ^Tx, store: u32) -> bool {
	if tx.mode == .Version_Change { return true }
	for s in tx.scope { if s == store { return true } }
	return false
}

// Executes one request of transaction `id` and writes its reply. The error is what the script's request fails with.
tx_exec :: proc(c: ^Client, id: u64, req: []byte, reply: ^Writer) -> Error {
	sync.recursive_mutex_lock(&c.m.mu); defer sync.recursive_mutex_unlock(&c.m.mu)
	m := c.m
	context.allocator = m.allocator
	tx, ok := m.txs[id]
	if !ok || tx.client != c || tx.state != .Active { return .Invalid_State }
	undo_mark, redo_mark, reply_mark, changed := len(tx.undo.entries), len(tx.redo.data), len(reply.data), tx.x.changed
	err := exec_request(tx, req, reply)
	if err != .None {
		if len(tx.undo.entries) > undo_mark { undo_rollback(tx.x.d, &tx.undo, undo_mark) }
		resize(&tx.redo.data, redo_mark)
		resize(&reply.data, reply_mark)
		tx.x.changed = changed
	}
	return err
}

@(private)
exec_request :: proc(tx: ^Tx, req: []byte, reply: ^Writer) -> Error {
	r := Reader{data = req}
	op := Request_Op(r_u8(&r))
	if r.bad || op == .None || op > max(Request_Op) { return .Data }
	x := &tx.x
	db := x.db
	if db == nil { return .Not_Found }
	writes := false
	ddl := false
	switch op {
	case .None, .Get, .Count, .Get_All, .Cursor, .Peek_Key:
	case .Put, .Gen_Key, .Delete, .Clear, .Index_Put: writes = true
	case .Create_Store, .Delete_Store, .Rename_Store, .Create_Index, .Delete_Index, .Rename_Index: writes = true; ddl = true
	}
	if writes && tx.mode == .Read_Only { return .Read_Only }
	if ddl && tx.mode != .Version_Change { return .Invalid_State }

	store_id: u32
	s: ^Store
	if op != .Create_Store {
		store_id = u32(r_uv(&r))
		if r.bad { return .Data }
		if !in_scope(tx, store_id) { return .Invalid_State }
		s = find_store(db, store_id)
		if s == nil { return .Not_Found }
	}
	source :: proc(s: ^Store, r: ^Reader) -> (Source, bool) {
		ix := u32(r_uv(r))
		if ix == 0 { return Source{store = s}, true }
		i := find_index(s, ix)
		return Source{store = s, index = i}, i != nil
	}

	switch op {
	case .None: return .Data
	case .Get:
		src, found_ix := source(s, &r)
		rng := r_range(&r)
		key_only := r_u8(&r) != 0
		if r.bad { return .Data }
		if !found_ix { return .Not_Found }
		hit, found := first_in_range(src, rng)
		w_u8(reply, 1 if found else 0)
		if found {
			w_bytes(reply, hit.pk)
			if !key_only { w_bytes(reply, hit.rec.value) }
		}
	case .Count:
		src, found_ix := source(s, &r)
		rng := r_range(&r)
		if r.bad { return .Data }
		if !found_ix { return .Not_Found }
		w_uv(reply, u64(count_range(src, rng)))
	case .Get_All:
		src, found_ix := source(s, &r)
		rng := r_range(&r)
		mode := r_u8(&r)
		flags := r_u8(&r)
		limit := int(r_uv(&r))
		if r.bad || mode < 1 || mode > 3 { return .Data }
		if !found_ix { return .Not_Found }
		Ctx :: struct { w: ^Writer, mode: u8, mark: int, n: int }
		// the count comes first: written after the walk, at the place reserved
		body: Writer
		defer writer_destroy(&body)
		ctx := Ctx{w = &body, mode = mode}
		visit :: proc(user: rawptr, key, pk: []byte, rec: ^Record) -> bool {
			c := (^Ctx)(user)
			if c.mode == 3 { w_bytes(c.w, key) }
			if c.mode != 2 { w_bytes(c.w, pk) }
			if c.mode != 1 { w_bytes(c.w, rec.value) }
			c.n += 1
			return true
		}
		if flags & 2 != 0 {
			// distinct keys only (the unique directions): one record per key, by cursor steps
			q := Cursor_Request{range = rng, direction = .Prev_Unique if flags & 1 != 0 else .Next_Unique}
			for limit <= 0 || ctx.n < limit {
				hit, found := cursor_step(src, q)
				if !found { break }
				visit(&ctx, hit.key, hit.pk, hit.rec)
				q.has_cur, q.cur_key, q.cur_pk = true, hit.key, hit.pk
			}
		} else {
			scan(src, rng, flags & 1 != 0, limit if limit > 0 else -1, visit, &ctx)
		}
		w_uv(reply, u64(ctx.n))
		append(&reply.data, ..body.data[:])
	case .Cursor:
		src, found_ix := source(s, &r)
		q: Cursor_Request
		q.range = r_range(&r)
		dir := r_u8(&r)
		if dir > 3 { return .Data }
		q.direction = Direction(dir)
		q.has_cur = r_u8(&r) != 0
		q.cur_key = r_bytes(&r)
		q.cur_pk = r_bytes(&r)
		q.has_target = r_u8(&r) != 0
		q.target = r_bytes(&r)
		q.has_target_pk = r_u8(&r) != 0
		q.target_pk = r_bytes(&r)
		q.count = int(r_uv(&r))
		key_only := r_u8(&r) != 0
		if r.bad { return .Data }
		if !found_ix { return .Not_Found }
		hit, found := cursor_step(src, q)
		w_u8(reply, 1 if found else 0)
		if found {
			w_bytes(reply, hit.key)
			w_bytes(reply, hit.pk)
			if !key_only { w_bytes(reply, hit.rec.value) }
		}
	case .Put:
		flags := r_u8(&r)
		key: []byte
		if flags & 2 != 0 { key = r_bytes(&r); if key == nil { key = {} } }
		value := r_bytes(&r)
		n := int(r_uv(&r))
		if r.bad || n > len(req) { return .Data }
		ikeys := make([]Index_Key, n, context.temp_allocator)
		for i in 0 ..< n {
			ikeys[i].index = u32(r_uv(&r))
			ikeys[i].key = r_bytes(&r)
		}
		if r.bad { return .Data }
		k, err := exec_put(x, store_id, key if flags & 2 != 0 else nil, value, ikeys, flags & 1 != 0, flags & 4 != 0)
		if err != .None { return err }
		w_bytes(reply, k)
	case .Peek_Key:
		if !s.auto_increment { return .Data }
		if s.gen > KEY_GEN_LIMIT { return .Constraint }
		k := key_of_number(s.gen, context.temp_allocator)
		w_bytes(reply, k)
	case .Gen_Key:
		k, err := exec_generate_key(x, store_id, context.temp_allocator)
		if err != .None { return err }
		w_bytes(reply, k)
	case .Delete:
		rng := r_range(&r)
		if r.bad { return .Data }
		return exec_delete_range(x, store_id, rng)
	case .Clear:
		return exec_clear(x, store_id)
	case .Index_Put:
		index := u32(r_uv(&r))
		pk := r_bytes(&r)
		n := int(r_uv(&r))
		if r.bad || n > len(req) { return .Data }
		keys := make([][]byte, n, context.temp_allocator)
		for i in 0 ..< n { keys[i] = r_bytes(&r) }
		if r.bad { return .Data }
		return exec_index_put(x, store_id, index, pk, keys)
	case .Create_Store:
		name := r_str(&r)
		kp := r_bytes(&r)
		flags := r_u8(&r)
		if r.bad { return .Data }
		sid, err := exec_create_store(x, name, kp, flags & 1 != 0)
		if err != .None { return err }
		w_uv(reply, u64(sid))
	case .Delete_Store: return exec_delete_store(x, store_id)
	case .Rename_Store:
		name := r_str(&r)
		if r.bad { return .Data }
		return exec_rename_store(x, store_id, name)
	case .Create_Index:
		name := r_str(&r)
		kp := r_bytes(&r)
		flags := r_u8(&r)
		if r.bad { return .Data }
		iid, err := exec_create_index(x, store_id, name, kp, flags & 1 != 0, flags & 2 != 0)
		if err != .None { return err }
		w_uv(reply, u64(iid))
	case .Delete_Index:
		index := u32(r_uv(&r))
		if r.bad { return .Data }
		return exec_delete_index(x, store_id, index)
	case .Rename_Index:
		index := u32(r_uv(&r))
		name := r_str(&r)
		if r.bad { return .Data }
		return exec_rename_index(x, store_id, index, name)
	}
	return .None
}
