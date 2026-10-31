// model_cursor.odin: IDBCursor / IDBCursorWithValue, IDBDatabase, IDBTransaction, and the browser's events (hooks.event
// reads one with call(11) and acts). Ported from web_idb_prelude.c (same names).
//
// The cursor state C is an engine object in cursorState; key / pk are Uint8Array keys (or null), kv / pv their decoded
// values cached until the cursor moves (kv_cached / pv_cached).
package idb

import "../wj"

DIRECTIONS := [4]cstring{ "next", "nextunique", "prev", "prevunique" }

// srcDeleted(C): S.meta.deleted || (index && index.deleted)
cursor_src_deleted :: proc "contextless" (ctx: ^wj.Context, C: wj.JSValue) -> bool {
	S := pget(ctx, C, "store")
	meta := pget(ctx, S, "meta")
	d := pbool(ctx, meta, "deleted")
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, S)
	if d { return true }
	index := pget(ctx, C, "index")
	id := !wj.is_null(index) && pbool(ctx, index, "deleted")
	wj.JS_FreeValue(ctx, index)
	return id
}

// The transaction state of a cursor (its request's), counted.
@(private = "file")
cursor_tx :: proc "contextless" (ctx: ^wj.Context, C: wj.JSValue) -> wj.JSValue {
	R := pget(ctx, C, "R")
	T := pget(ctx, R, "tx")
	wj.JS_FreeValue(ctx, R)
	return T
}

// cursorExec(C, target, targetPk, count): execCursor, update C; returns C.wrapper or null
cursor_exec :: proc "contextless" (ctx: ^wj.Context, C: wj.JSValue, target: wj.JSValue, target_pk: wj.JSValue, count: u32) -> wj.JSValue {
	S := pget(ctx, C, "store")
	meta := pget(ctx, S, "meta")
	store := u64(pint(ctx, meta, "id"))
	index := pget(ctx, C, "index")
	index_id := wj.is_null(index) ? 0 : u64(pint(ctx, index, "id"))
	T := cursor_tx(ctx, C)
	txid := u64(pint(ctx, T, "id"))
	range := pget(ctx, C, "range")
	rbytes := pack_range(ctx, range)
	dir := i32(pint(ctx, C, "direction"))
	key := pget(ctx, C, "key")
	pk := pget(ctx, C, "pk")
	key_only := pbool(ctx, C, "keyOnly")
	a := [11]wj.JSValue{
		wj.new_int64(ctx, i64(txid)), wj.new_int64(ctx, i64(store)), wj.new_int64(ctx, i64(index_id)), rbytes, wj.new_int32(dir),
		key, pk, target, target_pk, wj.new_int64(ctx, i64(count)), wj.new_bool(key_only),
	}
	rep := wj.JS_Call(ctx, M.h_execCursor, M.host, 11, &a[0])
	wj.JS_FreeValue(ctx, rbytes)
	wj.JS_FreeValue(ctx, range)
	wj.JS_FreeValue(ctx, key)
	wj.JS_FreeValue(ctx, pk)
	wj.JS_FreeValue(ctx, index)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, S)
	wj.JS_FreeValue(ctx, T)
	if wj.is_exception(rep) { return rep }
	if wj.is_null(rep) {
		pset(ctx, C, "key", wj.NULL)
		pset(ctx, C, "pk", wj.NULL)
		pset(ctx, C, "kv_cached", wj.FALSE)
		pset(ctx, C, "pv_cached", wj.FALSE)
		pset(ctx, C, "value", wj.UNDEFINED)
		pset(ctx, C, "gotValue", wj.FALSE)
		return wj.NULL
	}
	pset(ctx, C, "key", wj.JS_GetPropertyUint32(ctx, rep, 0))
	pset(ctx, C, "pk", wj.JS_GetPropertyUint32(ctx, rep, 1))
	pset(ctx, C, "kv_cached", wj.FALSE)
	pset(ctx, C, "pv_cached", wj.FALSE)
	pset(ctx, C, "value", wj.JS_GetPropertyUint32(ctx, rep, 2))
	pset(ctx, C, "gotValue", wj.TRUE)
	wj.JS_FreeValue(ctx, rep)
	return pget(ctx, C, "wrapper")
}

// step(C, target, targetPk, count): re-ask through the cursor's own request
cursor_step :: proc "contextless" (ctx: ^wj.Context, C, T, target, target_pk: wj.JSValue, count: u32) {
	pset(ctx, C, "gotValue", wj.FALSE)
	R := pget(ctx, C, "R")
	pstr(ctx, R, "readyState", "pending")
	pset(ctx, R, "result", wj.UNDEFINED)
	d := [5]wj.JSValue{ T, C, target, target_pk, wj.new_int64(ctx, i64(count)) }
	enqueue(ctx, T, R, make_exec(ctx, EX_CURSOR, d[:]))
	wj.JS_FreeValue(ctx, R)
}

open_cursor :: proc "contextless" (ctx: ^wj.Context, S, index, T, src, query, direction: wj.JSValue, key_only: bool) -> wj.JSValue {
	range := range_arg(ctx, query, true)
	if wj.is_exception(range) { return range }
	dirv := wj.is_undefined(direction) ? wj.new_string(ctx, "next") : wj.JS_DupValue(ctx, direction)
	dir, ok := check_enum(ctx, dirv, DIRS[:], "IDBCursorDirection")
	wj.JS_FreeValue(ctx, dirv)
	if !ok { wj.JS_FreeValue(ctx, range); return wj.EXCEPTION }
	reqs := new_request(ctx, M.proto_IDBRequest, src, T)
	Rw := pget(ctx, reqs, "wrapper")
	et_init(ctx, Rw)
	w := obj_create(ctx, key_only ? M.proto_IDBCursor : M.proto_IDBCursorWithValue)
	C := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, C, "R", wj.JS_DupValue(ctx, reqs))
	wj.JS_SetPropertyStr(ctx, C, "range", wj.JS_DupValue(ctx, range))
	wj.JS_SetPropertyStr(ctx, C, "direction", wj.new_int32(i32(dir)))
	wj.JS_SetPropertyStr(ctx, C, "keyOnly", wj.new_bool(key_only))
	wj.JS_SetPropertyStr(ctx, C, "key", wj.NULL)
	wj.JS_SetPropertyStr(ctx, C, "pk", wj.NULL)
	wj.JS_SetPropertyStr(ctx, C, "kv_cached", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, C, "pv_cached", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, C, "kv", wj.UNDEFINED)
	wj.JS_SetPropertyStr(ctx, C, "pv", wj.UNDEFINED)
	wj.JS_SetPropertyStr(ctx, C, "value", wj.UNDEFINED)
	wj.JS_SetPropertyStr(ctx, C, "gotValue", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, C, "store", wj.JS_DupValue(ctx, S))
	wj.JS_SetPropertyStr(ctx, C, "index", wj.JS_DupValue(ctx, index))
	wj.JS_SetPropertyStr(ctx, C, "sourceWrapper", wj.JS_DupValue(ctx, src))
	wj.JS_SetPropertyStr(ctx, C, "wrapper", wj.JS_DupValue(ctx, w))
	wm_set(ctx, M.cursorState, w, C)
	d := [5]wj.JSValue{ T, C, wj.NULL, wj.NULL, wj.new_int32(1) }
	enqueue(ctx, T, reqs, make_exec(ctx, EX_CURSOR, d[:]))
	wj.JS_FreeValue(ctx, C)
	wj.JS_FreeValue(ctx, w)
	wj.JS_FreeValue(ctx, range)
	wj.JS_FreeValue(ctx, reqs)
	return Rw
}

// ---- IDBCursor accessors and methods ----

@(private = "file")
cursor_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	r := pget(ctx, C, field)
	wj.JS_FreeValue(ctx, C)
	return r
}

cursor_get_source :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return cursor_field(ctx, this_val, "sourceWrapper") }
cursorwv_get_value :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return cursor_field(ctx, this_val, "value") }

cursor_get_direction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	d := pint(ctx, C, "direction")
	wj.JS_FreeValue(ctx, C)
	return wj.new_string(ctx, DIRECTIONS[d])
}

// key / primaryKey: the decoded value of the cursor's key, cached until it moves
@(private = "file")
cursor_decoded :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field, cached, flag: cstring) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	defer wj.JS_FreeValue(ctx, C)
	key := pget(ctx, C, field)
	defer wj.JS_FreeValue(ctx, key)
	if wj.is_null(key) { return wj.UNDEFINED }
	if !pbool(ctx, C, flag) {
		pset(ctx, C, cached, key_value(ctx, key))
		pset(ctx, C, flag, wj.TRUE)
	}
	return pget(ctx, C, cached)
}
cursor_get_key        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return cursor_decoded(ctx, this_val, "key", "kv", "kv_cached") }
cursor_get_primaryKey :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return cursor_decoded(ctx, this_val, "pk", "pv", "pv_cached") }

cursor_get_request :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	R := cursor_field(ctx, this_val, "R")
	if wj.is_exception(R) { return R }
	w := pget(ctx, R, "wrapper")
	wj.JS_FreeValue(ctx, R)
	return w
}

// cursorReady(C): active transaction, source not deleted, gotValue; the transaction in T (counted) or throws
cursor_ready :: proc "contextless" (ctx: ^wj.Context, C: wj.JSValue, T: ^wj.JSValue) -> bool {
	tx := cursor_tx(ctx, C)
	if !pstr_eq(ctx, tx, "state", "active") { wj.JS_FreeValue(ctx, tx); throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); return false }
	if cursor_src_deleted(ctx, C) { wj.JS_FreeValue(ctx, tx); throw_dom(ctx, "InvalidStateError", "The cursor's source has been deleted."); return false }
	if !pbool(ctx, C, "gotValue") { wj.JS_FreeValue(ctx, tx); throw_dom(ctx, "InvalidStateError", "The cursor is being iterated or has iterated past its end."); return false }
	T^ = tx
	return true
}

cursor_advance :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	defer wj.JS_FreeValue(ctx, C)
	if !arity(ctx, 1, argc, "advance", "IDBCursor") { return wj.EXCEPTION }
	n: u32
	if !enforce_u_long(ctx, argv[0], "count", &n) { return wj.EXCEPTION }
	if n == 0 { return type_error(ctx, "A count of 0 is not valid.") }
	T: wj.JSValue
	if !cursor_ready(ctx, C, &T) { return wj.EXCEPTION }
	cursor_step(ctx, C, T, wj.NULL, wj.NULL, n)
	wj.JS_FreeValue(ctx, T)
	return wj.UNDEFINED
}

// Whether the cursor goes forward (next / nextunique).
@(private = "file")
forward :: proc "contextless" (ctx: ^wj.Context, C: wj.JSValue) -> bool { return pint(ctx, C, "direction") < 2 }

cursor_continue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	defer wj.JS_FreeValue(ctx, C)
	T: wj.JSValue
	if !cursor_ready(ctx, C, &T) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, T)
	key := wj.arg(argc, argv, 0)
	target := wj.NULL
	if !wj.is_undefined(key) {
		target = key_of(ctx, key)
		if wj.is_exception(target) { return target }
		if wj.is_null(target) { return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
		ckey := pget(ctx, C, "key")
		c := cmp_bytes(ctx, target, ckey)
		wj.JS_FreeValue(ctx, ckey)
		fwd := forward(ctx, C)
		if (fwd && c <= 0) || (!fwd && c >= 0) {
			wj.JS_FreeValue(ctx, target)
			return throw_dom(ctx, "DataError", "The parameter is less than or equal to this cursor's position.")
		}
	}
	cursor_step(ctx, C, T, target, wj.NULL, 1)
	wj.JS_FreeValue(ctx, target)
	return wj.UNDEFINED
}

cursor_continuePrimaryKey :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	defer wj.JS_FreeValue(ctx, C)
	if !arity(ctx, 2, argc, "continuePrimaryKey", "IDBCursor") { return wj.EXCEPTION }
	T := cursor_tx(ctx, C)
	defer wj.JS_FreeValue(ctx, T)
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "TransactionInactiveError", "The transaction is not active.") }
	if cursor_src_deleted(ctx, C) { return throw_dom(ctx, "InvalidStateError", "The cursor's source has been deleted.") }
	index := pget(ctx, C, "index")
	noix := wj.is_null(index)
	wj.JS_FreeValue(ctx, index)
	if noix { return throw_dom(ctx, "InvalidAccessError", "The cursor's source is not an index.") }
	dir := pint(ctx, C, "direction")
	if dir == 1 || dir == 3 { return throw_dom(ctx, "InvalidAccessError", "The cursor's direction is a unique one.") }
	if !pbool(ctx, C, "gotValue") { return throw_dom(ctx, "InvalidStateError", "The cursor is being iterated or has iterated past its end.") }
	k := key_of(ctx, argv[0])
	if wj.is_exception(k) { return k }
	if wj.is_null(k) { return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
	pk := key_of(ctx, argv[1])
	if wj.is_exception(pk) { wj.JS_FreeValue(ctx, k); return pk }
	if wj.is_null(pk) { wj.JS_FreeValue(ctx, k); return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
	defer { wj.JS_FreeValue(ctx, k); wj.JS_FreeValue(ctx, pk) }
	ckey := pget(ctx, C, "key")
	cpk := pget(ctx, C, "pk")
	c := cmp_bytes(ctx, k, ckey)
	fwd := forward(ctx, C)
	bad := (fwd && (c < 0 || (c == 0 && cmp_bytes(ctx, pk, cpk) <= 0))) || (!fwd && (c > 0 || (c == 0 && cmp_bytes(ctx, pk, cpk) >= 0)))
	wj.JS_FreeValue(ctx, ckey)
	wj.JS_FreeValue(ctx, cpk)
	if bad { return throw_dom(ctx, "DataError", "The parameters are less than or equal to this cursor's position.") }
	cursor_step(ctx, C, T, k, pk, 1)
	return wj.UNDEFINED
}

// The checks update() and delete() share: an active, writable transaction, a live source, a value cursor in place.
@(private = "file")
cursor_writable :: proc "contextless" (ctx: ^wj.Context, C: wj.JSValue, T: wj.JSValue) -> bool {
	if !pstr_eq(ctx, T, "state", "active") { throw_dom(ctx, "TransactionInactiveError", "The transaction is not active."); return false }
	if pstr_eq(ctx, T, "mode", "readonly") { throw_dom(ctx, "ReadOnlyError", "The transaction is read-only."); return false }
	if cursor_src_deleted(ctx, C) { throw_dom(ctx, "InvalidStateError", "The cursor's source has been deleted."); return false }
	if !pbool(ctx, C, "gotValue") || pbool(ctx, C, "keyOnly") { throw_dom(ctx, "InvalidStateError", "The cursor is being iterated, past its end, or a key cursor."); return false }
	return true
}

cursor_update :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	defer wj.JS_FreeValue(ctx, C)
	if !arity(ctx, 1, argc, "update", "IDBCursor") { return wj.EXCEPTION }
	T := cursor_tx(ctx, C)
	defer wj.JS_FreeValue(ctx, T)
	if !cursor_writable(ctx, C, T) { return wj.EXCEPTION }
	value := argv[0]
	bytes := clone_value(ctx, T, value)
	if wj.is_exception(bytes) { return bytes }
	S := pget(ctx, C, "store")
	meta := pget(ctx, S, "meta")
	kp := pget(ctx, meta, "keyPath")
	defer { wj.JS_FreeValue(ctx, kp); wj.JS_FreeValue(ctx, bytes); wj.JS_FreeValue(ctx, meta); wj.JS_FreeValue(ctx, S) }
	indexes := pget(ctx, meta, "indexes")
	ni: i64
	wj.JS_GetLength(ctx, indexes, &ni)
	wj.JS_FreeValue(ctx, indexes)
	need_eval := wj.is_object(value) && (!wj.is_null(kp) || ni > 0)
	eval_value := need_eval ? deserialize(ctx, bytes) : wj.JS_DupValue(ctx, value)
	defer wj.JS_FreeValue(ctx, eval_value)
	if !wj.is_null(kp) {
		k := call2(ctx, M.h_pathKey, eval_value, kp)
		cpk := pget(ctx, C, "pk")
		bad := wj.is_nullish(k) || cmp_bytes(ctx, k, cpk) != 0
		wj.JS_FreeValue(ctx, cpk)
		wj.JS_FreeValue(ctx, k)
		if bad { return throw_dom(ctx, "DataError", "The effective key of the value differs from the cursor's primary key.") }
	}
	reqs := new_request(ctx, M.proto_IDBRequest, this_val, T)
	Rw := pget(ctx, reqs, "wrapper")
	et_init(ctx, Rw)
	snapshot := snap_index_keys(ctx, meta, eval_value)
	pk := pget(ctx, C, "pk")
	d := [8]wj.JSValue{ T, meta, wj.new_int32(2), pk, bytes, kp, wj.FALSE, snapshot }
	enqueue(ctx, T, reqs, make_exec(ctx, EX_PUT, d[:]))
	wj.JS_FreeValue(ctx, pk)
	wj.JS_FreeValue(ctx, snapshot)
	wj.JS_FreeValue(ctx, reqs)
	return Rw
}

cursor_delete :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	C := state_of(ctx, M.cursorState, this_val)
	if wj.is_exception(C) { return C }
	defer wj.JS_FreeValue(ctx, C)
	T := cursor_tx(ctx, C)
	defer wj.JS_FreeValue(ctx, T)
	if !cursor_writable(ctx, C, T) { return wj.EXCEPTION }
	reqs := new_request(ctx, M.proto_IDBRequest, this_val, T)
	Rw := pget(ctx, reqs, "wrapper")
	et_init(ctx, Rw)
	S := pget(ctx, C, "store")
	meta := pget(ctx, S, "meta")
	pk := pget(ctx, C, "pk")
	// a one-point range on the primary key
	r := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, r, "lower", wj.JS_DupValue(ctx, pk))
	wj.JS_SetPropertyStr(ctx, r, "upper", wj.JS_DupValue(ctx, pk))
	wj.JS_SetPropertyStr(ctx, r, "lowerOpen", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, r, "upperOpen", wj.FALSE)
	rbytes := pack_range(ctx, r)
	d := [3]wj.JSValue{ T, meta, rbytes }
	enqueue(ctx, T, reqs, make_exec(ctx, EX_DELETE, d[:]))
	wj.JS_FreeValue(ctx, rbytes)
	wj.JS_FreeValue(ctx, r)
	wj.JS_FreeValue(ctx, pk)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, S)
	wj.JS_FreeValue(ctx, reqs)
	return Rw
}

// ---- IDBDatabase ----

@(private = "file")
db_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	c := state_of(ctx, M.dbState, this_val)
	if wj.is_exception(c) { return c }
	r := pget(ctx, c, field)
	wj.JS_FreeValue(ctx, c)
	return r
}
db_get_name             :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return db_field(ctx, this_val, "name") }
db_get_version          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return db_field(ctx, this_val, "version") }
db_get_objectStoreNames :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return db_field(ctx, this_val, "names") }

// A key path option as the store / index keeps it: an array's elements and a string converted to strings.
@(private = "file")
key_path_strings :: proc "contextless" (ctx: ^wj.Context, kp: wj.JSValue) -> wj.JSValue {
	if !wj.JS_IsArray(kp) { return to_str(ctx, kp) }
	l: i64
	wj.JS_GetLength(ctx, kp, &l)
	out := wj.JS_NewArray(ctx)
	for i in 0 ..< l {
		e := wj.JS_GetPropertyInt64(ctx, kp, i)
		wj.JS_SetPropertyInt64(ctx, out, i, to_str(ctx, e))
		wj.JS_FreeValue(ctx, e)
	}
	return out
}

db_createObjectStore :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := state_of(ctx, M.dbState, this_val)
	if wj.is_exception(c) { return c }
	defer wj.JS_FreeValue(ctx, c)
	if !arity(ctx, 1, argc, "createObjectStore", "IDBDatabase") { return wj.EXCEPTION }
	nv := to_str(ctx, argv[0])   // the name stays a JS string: U+0000 and lone surrogates must survive
	if wj.is_exception(nv) { return wj.EXCEPTION }
	key_path := wj.NULL
	defer { wj.JS_FreeValue(ctx, nv); wj.JS_FreeValue(ctx, key_path) }
	auto_increment := false
	options := wj.arg(argc, argv, 1)
	if !wj.is_nullish(options) {
		if !wj.is_object(options) { return type_error(ctx, "The options argument is not of type 'IDBObjectStoreParameters'.") }
		auto_increment = rsb(ctx, options, "autoIncrement")
		kp := wj.JS_GetPropertyStr(ctx, options, "keyPath")
		if !wj.is_nullish(kp) { key_path = key_path_strings(ctx, kp) }
		wj.JS_FreeValue(ctx, kp)
	}
	T := pget(ctx, c, "upgradeTx")
	defer wj.JS_FreeValue(ctx, T)
	if wj.is_null(T) { return throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction.") }
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "TransactionInactiveError", "The transaction is not active.") }
	if !wj.is_null(key_path) {
		valid := call1(ctx, M.h_validPath, key_path)
		ok := wj.JS_ToBool(ctx, valid) != 0
		wj.JS_FreeValue(ctx, valid)
		if !ok { return throw_dom(ctx, "SyntaxError", "The keyPath option is not a valid key path.") }
	}
	stores := pget(ctx, c, "stores")
	defer wj.JS_FreeValue(ctx, stores)
	sn: i64
	wj.JS_GetLength(ctx, stores, &sn)
	clash := false
	for i: i64 = 0; i < sn && !clash; i += 1 {
		s := wj.JS_GetPropertyInt64(ctx, stores, i)
		clash = pstr_eq_val(ctx, s, "name", nv)
		wj.JS_FreeValue(ctx, s)
	}
	if clash { return throw_dom(ctx, "ConstraintError", "An object store with the specified name already exists.") }
	kp_empty := wj.is_string(key_path) && is_empty_string(ctx, key_path)
	if auto_increment && (kp_empty || wj.JS_IsArray(key_path)) {
		return throw_dom(ctx, "InvalidAccessError", "The autoIncrement option was set but the keyPath option was empty or an array.")
	}
	meta := wj.JS_NewObject(ctx)
	set_own(ctx, meta, "id", wj.new_int32(0))
	wj.JS_SetPropertyStr(ctx, meta, "name", wj.JS_DupValue(ctx, nv))
	wj.JS_SetPropertyStr(ctx, meta, "keyPath", frozen_path(ctx, key_path))
	wj.JS_SetPropertyStr(ctx, meta, "autoIncrement", wj.new_bool(auto_increment))
	wj.JS_SetPropertyStr(ctx, meta, "indexes", wj.JS_NewArray(ctx))
	wj.JS_SetPropertyStr(ctx, meta, "hostIndexes", wj.JS_NewArray(ctx))
	wj.JS_SetPropertyStr(ctx, meta, "deleted", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, meta, "ready", wj.FALSE)
	cur: i64
	wj.JS_GetLength(ctx, stores, &cur)
	wj.JS_SetPropertyInt64(ctx, stores, cur, wj.JS_DupValue(ctx, meta))
	update_names(ctx, c)
	d := [5]wj.JSValue{ T, meta, nv, key_path, wj.new_bool(auto_increment) }
	enqueue_internal(ctx, T, make_exec(ctx, EX_CREATE_STORE, d[:]))
	r := store_for(ctx, T, meta)
	wj.JS_FreeValue(ctx, meta)
	return r
}

db_deleteObjectStore :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := state_of(ctx, M.dbState, this_val)
	if wj.is_exception(c) { return c }
	defer wj.JS_FreeValue(ctx, c)
	if !arity(ctx, 1, argc, "deleteObjectStore", "IDBDatabase") { return wj.EXCEPTION }
	nv := to_str(ctx, argv[0])   // NUL-safe JS string for the name lookup
	if wj.is_exception(nv) { return wj.EXCEPTION }
	T := pget(ctx, c, "upgradeTx")
	defer { wj.JS_FreeValue(ctx, nv); wj.JS_FreeValue(ctx, T) }
	if wj.is_null(T) { return throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction.") }
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "TransactionInactiveError", "The transaction is not active.") }
	stores := pget(ctx, c, "stores")
	sn: i64
	wj.JS_GetLength(ctx, stores, &sn)
	at := i64(-1)
	for i in 0 ..< sn {
		s := wj.JS_GetPropertyInt64(ctx, stores, i)
		found := pstr_eq_val(ctx, s, "name", nv)
		wj.JS_FreeValue(ctx, s)
		if found { at = i; break }
	}
	if at < 0 { wj.JS_FreeValue(ctx, stores); return throw_dom(ctx, "NotFoundError", "The object store was not found.") }
	meta := wj.JS_GetPropertyInt64(ctx, stores, at)
	splice_one(ctx, stores, at)
	wj.JS_FreeValue(ctx, stores)
	pset(ctx, meta, "deleted", wj.TRUE)
	indexes := pget(ctx, meta, "indexes")
	n: i64
	wj.JS_GetLength(ctx, indexes, &n)
	for i in 0 ..< n {
		ix := wj.JS_GetPropertyInt64(ctx, indexes, i)
		pset(ctx, ix, "deleted", wj.TRUE)
		wj.JS_FreeValue(ctx, ix)
	}
	wj.JS_FreeValue(ctx, indexes)
	update_names(ctx, c)
	d := [2]wj.JSValue{ T, meta }
	enqueue_internal(ctx, T, make_exec(ctx, EX_DELETE_STORE, d[:]))
	wj.JS_FreeValue(ctx, meta)
	return wj.UNDEFINED
}

MODES := [3]string{ "readonly", "readwrite", "versionchange" }
@(private = "file") MODE_NAMES := [3]cstring{ "readonly", "readwrite", "versionchange" }
@(private = "file") DURABILITIES := [3]string{ "default", "strict", "relaxed" }
@(private = "file") DURABILITY_NAMES := [3]cstring{ "default", "strict", "relaxed" }

// The store names of transaction(storeNames): a string, or an iterable's elements as strings.
@(private = "file")
store_names_arg :: proc "contextless" (ctx: ^wj.Context, store_names: wj.JSValue) -> wj.JSValue {
	names := wj.JS_NewArray(ctx)
	iterable := false
	if !wj.is_string(store_names) && wj.is_object(store_names) {
		sym := g_prop(ctx, "Symbol")
		itv := wj.JS_GetPropertyStr(ctx, sym, "iterator")
		ia := wj.JS_ValueToAtom(ctx, itv)
		f := wj.JS_GetProperty(ctx, store_names, ia)
		iterable = wj.JS_IsFunction(ctx, f)
		wj.JS_FreeValue(ctx, f)
		wj.JS_FreeAtom(ctx, ia)
		wj.JS_FreeValue(ctx, itv)
		wj.JS_FreeValue(ctx, sym)
	}
	if wj.is_string(store_names) {
		wj.JS_SetPropertyUint32(ctx, names, 0, wj.JS_DupValue(ctx, store_names))
	} else if iterable {
		arrc := g_prop(ctx, "Array")
		sn := store_names
		list := method_call(ctx, arrc, "from", ([^]wj.JSValue)(&sn)[:1])
		wj.JS_FreeValue(ctx, arrc)
		if wj.is_exception(list) { wj.JS_FreeValue(ctx, names); return wj.EXCEPTION }
		l: i64
		wj.JS_GetLength(ctx, list, &l)
		for i in 0 ..< l {
			e := wj.JS_GetPropertyInt64(ctx, list, i)
			wj.JS_SetPropertyInt64(ctx, names, i, to_str(ctx, e))
			wj.JS_FreeValue(ctx, e)
		}
		wj.JS_FreeValue(ctx, list)
	} else {
		wj.JS_SetPropertyUint32(ctx, names, 0, to_str(ctx, store_names))
	}
	return names
}

db_transaction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := state_of(ctx, M.dbState, this_val)
	if wj.is_exception(c) { return c }
	defer wj.JS_FreeValue(ctx, c)
	if !arity(ctx, 1, argc, "transaction", "IDBDatabase") { return wj.EXCEPTION }
	names := store_names_arg(ctx, argv[0])
	if wj.is_exception(names) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, names)
	mode_in := argc > 1 && !wj.is_undefined(argv[1]) ? wj.JS_DupValue(ctx, argv[1]) : wj.new_string(ctx, "readonly")
	mode, mode_ok := check_enum(ctx, mode_in, MODES[:], "IDBTransactionMode")
	wj.JS_FreeValue(ctx, mode_in)
	if !mode_ok { return wj.EXCEPTION }
	durability := 0
	options := wj.arg(argc, argv, 2)
	if !wj.is_nullish(options) {
		if !wj.is_object(options) { return type_error(ctx, "The options argument is not of type 'IDBTransactionOptions'.") }
		dur := wj.JS_GetPropertyStr(ctx, options, "durability")
		if !wj.is_undefined(dur) {
			d, ok := check_enum(ctx, dur, DURABILITIES[:], "IDBTransactionDurability")
			if !ok { wj.JS_FreeValue(ctx, dur); return wj.EXCEPTION }
			durability = d
		}
		wj.JS_FreeValue(ctx, dur)
	}
	up := pget(ctx, c, "upgradeTx")
	running := !wj.is_null(up) && !pstr_eq(ctx, up, "state", "finished")
	wj.JS_FreeValue(ctx, up)
	if running { return throw_dom(ctx, "InvalidStateError", "A version change transaction is running.") }
	if pbool(ctx, c, "closePending") || pbool(ctx, c, "closed") { return throw_dom(ctx, "InvalidStateError", "The database connection is closing.") }
	nn: i64
	wj.JS_GetLength(ctx, names, &nn)
	if nn == 0 { return throw_dom(ctx, "InvalidAccessError", "The storeNames parameter is empty.") }
	scope := wj.JS_NewArray(ctx)
	defer wj.JS_FreeValue(ctx, scope)
	sk: u32
	stores := pget(ctx, c, "stores")
	for i in 0 ..< nn {
		nm := wj.JS_GetPropertyInt64(ctx, names, i)   // a JS string; compared NUL-safely and in full UTF-16
		meta, _ := find_store(ctx, stores, nm)
		wj.JS_FreeValue(ctx, nm)
		if wj.is_undefined(meta) { wj.JS_FreeValue(ctx, stores); return throw_dom(ctx, "NotFoundError", "One of the specified object stores was not found.") }
		dup := false
		for j: u32 = 0; j < sk && !dup; j += 1 {
			e := wj.JS_GetPropertyUint32(ctx, scope, j)
			dup = wj.same_ptr(e, meta)
			wj.JS_FreeValue(ctx, e)
		}
		if !dup { wj.JS_SetPropertyUint32(ctx, scope, sk, meta); sk += 1 } else { wj.JS_FreeValue(ctx, meta) }
	}
	wj.JS_FreeValue(ctx, stores)
	if mode == 2 { return type_error(ctx, "Failed to execute 'transaction' on 'IDBDatabase': The mode provided ('versionchange') is not one of 'readonly' or 'readwrite'.") }
	// sort scope by name in place, by UTF-16 code unit (as the spec and the old idb.js's .sort() do)
	scn: i64
	wj.JS_GetLength(ctx, scope, &scn)
	for i in 0 ..< scn {
		for j in i + 1 ..< scn {
			a := wj.JS_GetPropertyInt64(ctx, scope, i)
			b := wj.JS_GetPropertyInt64(ctx, scope, j)
			an := pget(ctx, a, "name")
			bn := pget(ctx, b, "name")
			swap := jsstr_cmp(ctx, an, bn) > 0
			wj.JS_FreeValue(ctx, an)
			wj.JS_FreeValue(ctx, bn)
			if swap { wj.JS_SetPropertyInt64(ctx, scope, i, b); wj.JS_SetPropertyInt64(ctx, scope, j, a) } else { wj.JS_FreeValue(ctx, a); wj.JS_FreeValue(ctx, b) }
		}
	}
	w := Wr{ ctx = ctx }
	wr_uv(&w, u64(pint(ctx, c, "id")))
	wr_u8(&w, mode == 1 ? 1 : 0)
	wr_u8(&w, durability == 1 ? 1 : 0)
	wr_uv(&w, u64(scn))
	for i in 0 ..< scn {
		s := wj.JS_GetPropertyInt64(ctx, scope, i)
		wr_uv(&w, u64(pint(ctx, s, "id")))
		wj.JS_FreeValue(ctx, s)
	}
	rep := host_call1(ctx, OP_BEGIN, wr_u8array(ctx, &w))
	wr_free(&w)
	defer wj.JS_FreeValue(ctx, rep)
	rp, ok := reply_bytes(ctx, rep)
	if !ok { return wj.EXCEPTION }
	if len(rp) > 0 && rp[0] != 0 { return throw_fail(ctx, i32(rp[0]), nil) }
	r := Rd{ p = rp, pos = 1 }
	id := rd_uv(&r)
	T := new_transaction(ctx, c, id, MODE_NAMES[mode], scope, DURABILITY_NAMES[durability])
	if rd_u8(&r) != 0 { pset(ctx, T, "started", wj.TRUE); pset(ctx, T, "startedEarly", wj.TRUE) }
	wrapper := pget(ctx, T, "wrapper")
	wj.JS_FreeValue(ctx, T)
	return wrapper
}

// The metadata of `stores` whose name is nm (counted), or undefined.
find_store :: proc "contextless" (ctx: ^wj.Context, stores: wj.JSValue, nm: wj.JSValue) -> (wj.JSValue, bool) {
	sn: i64
	wj.JS_GetLength(ctx, stores, &sn)
	for j in 0 ..< sn {
		s := wj.JS_GetPropertyInt64(ctx, stores, j)
		if pstr_eq_val(ctx, s, "name", nm) { return s, true }
		wj.JS_FreeValue(ctx, s)
	}
	return wj.UNDEFINED, false
}

db_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := state_of(ctx, M.dbState, this_val)
	if wj.is_exception(c) { return c }
	defer wj.JS_FreeValue(ctx, c)
	if pbool(ctx, c, "closePending") { return wj.UNDEFINED }
	pset(ctx, c, "closePending", wj.TRUE)
	w := Wr{ ctx = ctx }
	wr_uv(&w, u64(pint(ctx, c, "id")))
	wj.JS_FreeValue(ctx, host_call1(ctx, OP_CLOSE, wr_u8array(ctx, &w)))
	wr_free(&w)
	idv := wj.new_int64(ctx, pint(ctx, c, "id"))
	map_delete(ctx, M.conns, idv)
	wj.JS_FreeValue(ctx, idv)
	return wj.UNDEFINED
}

// ---- IDBTransaction ----

tx_get_objectStoreNames :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	T := state_of(ctx, M.txState, this_val)
	if wj.is_exception(T) { return T }
	defer wj.JS_FreeValue(ctx, T)
	if pstr_eq(ctx, T, "mode", "versionchange") {
		conn := pget(ctx, T, "conn")
		r := pget(ctx, conn, "names")
		wj.JS_FreeValue(ctx, conn)
		return r
	}
	names := pget(ctx, T, "names")
	if !wj.is_null(names) { return names }
	scope := pget(ctx, T, "scope")
	arr := wj.JS_NewArray(ctx)
	sn: i64
	wj.JS_GetLength(ctx, scope, &sn)
	for i in 0 ..< sn {
		s := wj.JS_GetPropertyInt64(ctx, scope, i)
		wj.JS_SetPropertyInt64(ctx, arr, i, pget(ctx, s, "name"))
		wj.JS_FreeValue(ctx, s)
	}
	list := make_list(ctx, arr)
	wj.JS_FreeValue(ctx, arr)
	wj.JS_FreeValue(ctx, scope)
	pset(ctx, T, "names", wj.JS_DupValue(ctx, list))
	return list
}

@(private = "file")
tx_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	T := state_of(ctx, M.txState, this_val)
	if wj.is_exception(T) { return T }
	r := pget(ctx, T, field)
	wj.JS_FreeValue(ctx, T)
	return r
}
tx_get_mode       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tx_field(ctx, this_val, "mode") }
tx_get_durability :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tx_field(ctx, this_val, "durability") }
tx_get_error      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tx_field(ctx, this_val, "error") }
tx_get_db :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	conn := tx_field(ctx, this_val, "conn")
	if wj.is_exception(conn) { return conn }
	r := pget(ctx, conn, "wrapper")
	wj.JS_FreeValue(ctx, conn)
	return r
}

tx_objectStore :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	T := state_of(ctx, M.txState, this_val)
	if wj.is_exception(T) { return T }
	defer wj.JS_FreeValue(ctx, T)
	if !arity(ctx, 1, argc, "objectStore", "IDBTransaction") { return wj.EXCEPTION }
	nv := to_str(ctx, argv[0])   // NUL-safe JS string for the name lookup
	if wj.is_exception(nv) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, nv)
	if pstr_eq(ctx, T, "state", "finished") { return throw_dom(ctx, "InvalidStateError", "The transaction has finished.") }
	src: wj.JSValue
	if pstr_eq(ctx, T, "mode", "versionchange") {
		conn := pget(ctx, T, "conn")
		src = pget(ctx, conn, "stores")
		wj.JS_FreeValue(ctx, conn)
	} else {
		src = pget(ctx, T, "scope")
	}
	meta, found := find_store(ctx, src, nv)
	wj.JS_FreeValue(ctx, src)
	if !found { return throw_dom(ctx, "NotFoundError", "The specified object store was not found.") }
	r := store_for(ctx, T, meta)
	wj.JS_FreeValue(ctx, meta)
	return r
}

tx_abort :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	T := state_of(ctx, M.txState, this_val)
	if wj.is_exception(T) { return T }
	defer wj.JS_FreeValue(ctx, T)
	if pstr_eq(ctx, T, "state", "committing") || pstr_eq(ctx, T, "state", "finished") { return throw_dom(ctx, "InvalidStateError", "The transaction is already finishing.") }
	abort_transaction(ctx, T, wj.NULL, E_ABORTED, true)
	return wj.UNDEFINED
}

tx_commit :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	T := state_of(ctx, M.txState, this_val)
	if wj.is_exception(T) { return T }
	defer wj.JS_FreeValue(ctx, T)
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "InvalidStateError", "The transaction is not active.") }
	pstr(ctx, T, "state", "committing")
	maybe_commit(ctx, T)
	return wj.UNDEFINED
}

// ---- the browser's events: hooks.event is called by wj_idb_event; it reads one event with call(11) and acts ----

// The entry of a Map under a numeric id (counted; undefined when none), removed from the map when `take`.
@(private = "file")
by_id :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, id: u64, take: bool) -> wj.JSValue {
	av := wj.new_int64(ctx, i64(id))
	v := map_get(ctx, m, av)
	if take && !wj.is_undefined(v) { map_delete(ctx, m, av) }
	wj.JS_FreeValue(ctx, av)
	return v
}

// The request's `name` as the connection's name ("" when the request had none).
@(private = "file")
request_name :: proc "contextless" (ctx: ^wj.Context, req: wj.JSValue) -> wj.JSValue {
	nm := pget(ctx, req, "name")
	if wj.is_undefined(nm) { return wj.new_string(ctx, "") }
	s := wj.JS_ToString(ctx, nm)
	wj.JS_FreeValue(ctx, nm)
	return s
}

// The fields of a browser event (src/page/idb_host.odin).
@(private = "file")
Host_Event :: struct {
	kind:                       u8,
	id, conn, tx, v1, v2, a:    u64,
	err:                        u8,
	data:                       []u8,   // a copy on the engine's heap (values may call back)
}

on_event_inner :: proc "contextless" (ctx: ^wj.Context) {
	rep := host_call0(ctx, OP_EVENT)
	if wj.is_exception(rep) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return }
	rp, ok := reply_bytes(ctx, rep)
	if !ok { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); wj.JS_FreeValue(ctx, rep); return }
	r := Rd{ p = rp, pos = 1 }
	e: Host_Event
	e.kind = rd_u8(&r)
	e.id = rd_uv(&r)
	e.conn = rd_uv(&r)
	e.tx = rd_uv(&r)
	e.v1 = rd_uv(&r)
	e.v2 = rd_uv(&r)
	e.a = rd_uv(&r)
	e.err = rd_u8(&r)
	payload := rd_bytes(&r)
	// keep the payload alive and position-independent: copy it (values may call back)
	dcopy := ([^]u8)(wj.js_malloc(ctx, uint(max(len(payload), 1))))
	if dcopy == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); wj.JS_FreeValue(ctx, rep); return }
	if len(payload) > 0 { wj.memcpy(dcopy, raw_data(payload), uint(len(payload))) }
	e.data = dcopy[:len(payload)]
	wj.JS_FreeValue(ctx, rep)   // rp is now dangling; use e.data
	handle_event(ctx, &e)
	wj.js_free(ctx, dcopy)
}

@(private = "file")
handle_event :: proc "contextless" (ctx: ^wj.Context, e: ^Host_Event) {
	switch e.kind {
	case EV_TASK:
		fn := by_id(ctx, M.tasks, e.a, true)
		if !wj.is_undefined(fn) {
			rr := wj.JS_Call(ctx, fn, wj.UNDEFINED, 0, nil)
			if wj.is_exception(rr) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, rr) }
		}
		wj.JS_FreeValue(ctx, fn)
	case EV_OPEN_UPGRADE:
		req := by_id(ctx, M.openReqs, e.id, false)
		if wj.is_undefined(req) { return }
		mr := Rd{ p = e.data }
		meta := read_meta(ctx, &mr)
		nm := request_name(ctx, req)
		c := new_connection(ctx, e.conn, nm, meta)
		wj.JS_FreeValue(ctx, nm)
		pset(ctx, c, "version", wj.new_int64(ctx, i64(e.v2)))
		scope := wj.JS_NewArray(ctx)
		T := new_transaction(ctx, c, e.tx, "versionchange", scope, "default")
		wj.JS_FreeValue(ctx, scope)
		pset(ctx, T, "started", wj.TRUE)
		pset(ctx, T, "upgradeReq", wj.JS_DupValue(ctx, req))
		pset(ctx, T, "oldVersion", wj.new_int64(ctx, i64(e.v1)))
		pset(ctx, T, "backup", snapshot_meta(ctx, c))
		pset(ctx, c, "upgradeTx", wj.JS_DupValue(ctx, T))
		pstr(ctx, req, "readyState", "done")
		pset(ctx, req, "result", pget(ctx, c, "wrapper"))
		pset(ctx, req, "error", wj.NULL)
		pset(ctx, req, "tx", wj.JS_DupValue(ctx, T))
		pset(ctx, req, "conn", wj.JS_DupValue(ctx, c))
		w := pget(ctx, req, "wrapper")
		out := dispatch(ctx, w, version_event(ctx, "upgradeneeded", f64(e.v1), true, f64(e.v2)))
		wj.JS_FreeValue(ctx, w)
		if out.threw && !pbool(ctx, T, "dead") {
			ab := dom_ex(ctx, "AbortError", "An exception was thrown by an upgradeneeded handler.")
			abort_transaction(ctx, T, ab, E_ABORTED, true)
			wj.JS_FreeValue(ctx, ab)
		}
		wj.JS_FreeValue(ctx, T)
		wj.JS_FreeValue(ctx, c)
		wj.JS_FreeValue(ctx, meta)
		wj.JS_FreeValue(ctx, req)
	case EV_OPEN_DONE:
		req := by_id(ctx, M.openReqs, e.id, true)
		if wj.is_undefined(req) { return }
		c := pget(ctx, req, "conn")
		if wj.is_undefined(c) {
			mr := Rd{ p = e.data }
			meta := read_meta(ctx, &mr)
			empty := wj.new_string(ctx, "")
			c = new_connection(ctx, e.conn, empty, meta)
			wj.JS_FreeValue(ctx, empty)
			pset(ctx, req, "conn", wj.JS_DupValue(ctx, c))
			wj.JS_FreeValue(ctx, meta)
		}
		pstr(ctx, req, "readyState", "done")
		pset(ctx, req, "result", pget(ctx, c, "wrapper"))
		pset(ctx, req, "error", wj.NULL)
		pset(ctx, req, "tx", wj.NULL)
		pset(ctx, c, "version", wj.new_int64(ctx, i64(e.v1)))
		w := pget(ctx, req, "wrapper")
		out := dispatch(ctx, w, plain_event(ctx, "success", false, false))
		if out.threw {
			cw := pget(ctx, c, "wrapper")
			method_void(ctx, cw, "close", nil)
			wj.JS_FreeValue(ctx, cw)
		}
		wj.JS_FreeValue(ctx, w)
		wj.JS_FreeValue(ctx, c)
		wj.JS_FreeValue(ctx, req)
	case EV_OPEN_ERROR:
		req := by_id(ctx, M.openReqs, e.id, true)
		if wj.is_undefined(req) { return }
		c := pget(ctx, req, "conn")
		if !wj.is_undefined(c) {
			pset(ctx, c, "closed", wj.TRUE)
			pset(ctx, c, "closePending", wj.TRUE)
			idv := wj.new_int64(ctx, pint(ctx, c, "id"))
			map_delete(ctx, M.conns, idv)
			wj.JS_FreeValue(ctx, idv)
		}
		wj.JS_FreeValue(ctx, c)
		open_error(ctx, req, i32(e.err))
		wj.JS_FreeValue(ctx, req)
	case EV_BLOCKED:
		req := by_id(ctx, M.openReqs, e.id, false)
		if wj.is_undefined(req) { return }
		is_delete := pbool(ctx, req, "isDelete")
		w := pget(ctx, req, "wrapper")
		dispatch(ctx, w, version_event(ctx, "blocked", f64(e.v1), !is_delete, f64(e.v2)))
		wj.JS_FreeValue(ctx, w)
		wj.JS_FreeValue(ctx, req)
	case EV_VERSION_CHANGE:
		c := by_id(ctx, M.conns, e.conn, false)
		if wj.is_undefined(c) { return }
		w := pget(ctx, c, "wrapper")
		dispatch(ctx, w, version_event(ctx, "versionchange", f64(e.v1), e.v2 != 0, f64(e.v2)))
		wj.JS_FreeValue(ctx, w)
		wj.JS_FreeValue(ctx, c)
		vn: i64
		wj.JS_GetLength(ctx, M.vcDone, &vn)
		wj.JS_SetPropertyInt64(ctx, M.vcDone, vn, wj.new_int64(ctx, i64(e.conn)))
		arm_cleanup(ctx)
	case EV_DELETE_DONE:
		req := by_id(ctx, M.openReqs, e.id, true)
		if wj.is_undefined(req) { return }
		pstr(ctx, req, "readyState", "done")
		pset(ctx, req, "result", wj.UNDEFINED)
		pset(ctx, req, "error", wj.NULL)
		w := pget(ctx, req, "wrapper")
		dispatch(ctx, w, version_event(ctx, "success", f64(e.v1), false, 0))
		wj.JS_FreeValue(ctx, w)
		wj.JS_FreeValue(ctx, req)
	case EV_DELETE_ERROR:
		req := by_id(ctx, M.openReqs, e.id, true)
		if wj.is_undefined(req) { return }
		open_error(ctx, req, i32(e.err))
		wj.JS_FreeValue(ctx, req)
	case EV_TX_STARTED:
		T := by_id(ctx, M.txs, e.tx, false)
		defer wj.JS_FreeValue(ctx, T)
		if wj.is_undefined(T) || pbool(ctx, T, "dead") { return }
		if pbool(ctx, T, "startedEarly") { pset(ctx, T, "startedEarly", wj.FALSE); return }
		pset(ctx, T, "started", wj.TRUE)
		process_next(ctx, T)
		queue := pget(ctx, T, "queue")
		n: i64
		wj.JS_GetLength(ctx, queue, &n)
		wj.JS_FreeValue(ctx, queue)
		if n == 0 { maybe_commit(ctx, T) }
	case EV_TX_COMPLETE:
		T := by_id(ctx, M.txs, e.tx, false)
		defer wj.JS_FreeValue(ctx, T)
		if wj.is_undefined(T) || pbool(ctx, T, "dead") { return }
		pstr(ctx, T, "state", "finished")
		pset(ctx, T, "dead", wj.TRUE)
		set_delete(ctx, M.activeSet, T)
		wj.JS_FreeValue(ctx, by_id(ctx, M.txs, e.tx, true))
		cn := pget(ctx, T, "conn")
		pset(ctx, cn, "txCount", wj.new_int64(ctx, pint(ctx, cn, "txCount") - 1))
		up := pget(ctx, cn, "upgradeTx")
		if wj.same_ptr(up, T) { pset(ctx, cn, "upgradeTx", wj.NULL) }
		wj.JS_FreeValue(ctx, up)
		w := pget(ctx, T, "wrapper")
		dispatch(ctx, w, plain_event(ctx, "complete", false, false))
		wj.JS_FreeValue(ctx, w)
		up_req := pget(ctx, T, "upgradeReq")
		if !wj.is_null(up_req) { pset(ctx, up_req, "tx", wj.NULL) }
		wj.JS_FreeValue(ctx, up_req)
		wj.JS_FreeValue(ctx, cn)
	case EV_TX_ABORTED:
		T := by_id(ctx, M.txs, e.tx, false)
		defer wj.JS_FreeValue(ctx, T)
		if wj.is_undefined(T) || pbool(ctx, T, "dead") { return }
		fv := fail_value(ctx, i32(e.err), "The transaction was aborted by the browser.")
		abort_transaction(ctx, T, fv, i32(e.err), false)
		wj.JS_FreeValue(ctx, fv)
	case EV_CONN_CLOSED:
		c := by_id(ctx, M.conns, e.conn, true)
		if wj.is_undefined(c) { return }
		pset(ctx, c, "closed", wj.TRUE)
		pset(ctx, c, "closePending", wj.TRUE)
		w := pget(ctx, c, "wrapper")
		dispatch(ctx, w, plain_event(ctx, "close", false, false))
		wj.JS_FreeValue(ctx, w)
		wj.JS_FreeValue(ctx, c)
	case EV_LIST:
		entry := by_id(ctx, M.listReqs, e.id, true)
		if wj.is_undefined(entry) { return }
		lr := Rd{ p = e.data }
		n := rd_uv(&lr)
		out := wj.JS_NewArray(ctx)
		for i: u64 = 0; i < n && !lr.bad; i += 1 {
			o := wj.JS_NewObject(ctx)
			wj.JS_SetPropertyStr(ctx, o, "name", wj.string_of_wtf8(ctx, rd_bytes(&lr)))
			wj.JS_SetPropertyStr(ctx, o, "version", wj.new_int64(ctx, i64(rd_uv(&lr))))
			wj.JS_SetPropertyUint32(ctx, out, u32(i), o)
		}
		resolve := wj.JS_GetPropertyStr(ctx, entry, "resolve")
		wj.JS_FreeValue(ctx, wj.JS_Call(ctx, resolve, wj.UNDEFINED, 1, &out))
		wj.JS_FreeValue(ctx, resolve)
		wj.JS_FreeValue(ctx, out)
		wj.JS_FreeValue(ctx, entry)
	}
}

hook_event :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	M.inHostEvent = true
	on_event_inner(ctx)
	M.inHostEvent = false
	return wj.UNDEFINED
}
hook_cleanup :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	cleanup_now(ctx)
	return wj.UNDEFINED
}
