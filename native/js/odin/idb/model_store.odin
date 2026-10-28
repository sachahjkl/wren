// model_store.odin: IDBObjectStore and IDBIndex (accessors and methods). Ported from web_idb_prelude.c (same names).
package idb

import "../wj"

// ---- IDBObjectStore ----

@(private = "file")
store_meta_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	meta := pget(ctx, S, "meta")
	v := pget(ctx, meta, field)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, S)
	return v
}

store_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return store_meta_field(ctx, this_val, "name") }

store_set_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, value: wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	// ToString(name) runs before any state check (spec order, as the old idb.js). The name stays a JS string so an
	// embedded U+0000 or a lone surrogate is preserved all the way to the host.
	nv := to_str(ctx, value)
	T := pget(ctx, S, "tx")
	meta := pget(ctx, S, "meta")
	defer { wj.JS_FreeValue(ctx, nv); wj.JS_FreeValue(ctx, meta); wj.JS_FreeValue(ctx, T); wj.JS_FreeValue(ctx, S) }
	if wj.is_exception(nv) { return wj.EXCEPTION }
	if !pstr_eq(ctx, T, "mode", "versionchange") { return throw_dom(ctx, "InvalidStateError", "The object store's name can only be changed in a version change transaction.") }
	if pbool(ctx, meta, "deleted") { return throw_dom(ctx, "InvalidStateError", "The object store has been deleted.") }
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "TransactionInactiveError", "The transaction is not active.") }
	if pstr_eq_val(ctx, meta, "name", nv) { return wj.UNDEFINED }
	conn := pget(ctx, T, "conn")
	stores := pget(ctx, conn, "stores")
	sn: i64
	wj.JS_GetLength(ctx, stores, &sn)
	clash := false
	for i: i64 = 0; i < sn && !clash; i += 1 {
		s := wj.JS_GetPropertyInt64(ctx, stores, i)
		clash = !wj.same_ptr(s, meta) && pstr_eq_val(ctx, s, "name", nv)
		wj.JS_FreeValue(ctx, s)
	}
	wj.JS_FreeValue(ctx, stores)
	if clash { wj.JS_FreeValue(ctx, conn); return throw_dom(ctx, "ConstraintError", "An object store with the specified name already exists.") }
	pset(ctx, meta, "name", wj.JS_DupValue(ctx, nv))
	update_names(ctx, conn)
	wj.JS_FreeValue(ctx, conn)
	d := [3]wj.JSValue{ T, meta, nv }
	enqueue_internal(ctx, T, make_exec(ctx, EX_RENAME_STORE, d[:]))
	return wj.UNDEFINED
}

store_get_keyPath :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	meta := pget(ctx, S, "meta")
	kp := pget(ctx, meta, "keyPath")
	r := key_path_of(ctx, S, kp)
	wj.JS_FreeValue(ctx, kp)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, S)
	return r
}

store_get_indexNames :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	meta := pget(ctx, S, "meta")
	names: wj.JSValue
	if pbool(ctx, meta, "deleted") {
		names = wj.JS_NewArray(ctx)
	} else {
		idx := pget(ctx, meta, "indexes")
		names = sorted_names(ctx, idx, "name")
		wj.JS_FreeValue(ctx, idx)
	}
	list := pget(ctx, S, "names")
	if wj.is_null(list) {
		list = make_list(ctx, names)
		pset(ctx, S, "names", wj.JS_DupValue(ctx, list))
	} else {
		c: i64
		wj.JS_GetLength(ctx, names, &c)
		set_list(ctx, list, names, c)
	}
	wj.JS_FreeValue(ctx, names)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, S)
	return list
}

store_get_transaction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	T := pget(ctx, S, "tx")
	w := pget(ctx, T, "wrapper")
	wj.JS_FreeValue(ctx, T)
	wj.JS_FreeValue(ctx, S)
	return w
}

store_get_autoIncrement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	v := store_meta_field(ctx, this_val, "autoIncrement")
	if wj.is_exception(v) { return v }
	b := wj.JS_ToBool(ctx, v) != 0
	wj.JS_FreeValue(ctx, v)
	return wj.new_bool(b)
}

store_put :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	if !arity(ctx, 1, argc, "put", "IDBObjectStore") { return wj.EXCEPTION }
	return do_put(ctx, S, argv[0], wj.arg(argc, argv, 1), false)
}

store_add :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	if !arity(ctx, 1, argc, "add", "IDBObjectStore") { return wj.EXCEPTION }
	return do_put(ctx, S, argv[0], wj.arg(argc, argv, 1), true)
}

// A request of the store S in T with an exec of `kind` over [T, meta, extra...]; its wrapper.
@(private = "file")
store_request :: proc "contextless" (ctx: ^wj.Context, S, T, src: wj.JSValue, kind: i32, extra: wj.JSValue, has_extra: bool) -> wj.JSValue {
	reqs := new_request(ctx, M.proto_IDBRequest, src, T)
	Rw := pget(ctx, reqs, "wrapper")
	et_init(ctx, Rw)
	meta := pget(ctx, S, "meta")
	d := [3]wj.JSValue{ T, meta, extra }
	enqueue(ctx, T, reqs, make_exec(ctx, kind, d[:has_extra ? 3 : 2]))
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, reqs)
	return Rw
}

store_delete :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	if !arity(ctx, 1, argc, "delete", "IDBObjectStore") { return wj.EXCEPTION }
	T: wj.JSValue
	if !check_store(ctx, S, true, &T) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, T)
	range := range_arg(ctx, argv[0], false)
	if wj.is_exception(range) { return range }
	rbytes := pack_range(ctx, range)
	Rw := store_request(ctx, S, T, this_val, EX_DELETE, rbytes, true)
	wj.JS_FreeValue(ctx, rbytes)
	wj.JS_FreeValue(ctx, range)
	return Rw
}

store_clear :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	T: wj.JSValue
	if !check_store(ctx, S, true, &T) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, T)
	return store_request(ctx, S, T, this_val, EX_CLEAR, wj.UNDEFINED, false)
}

// A read of the store: `this`'s state and its active transaction (both counted), or false with the error thrown.
@(private = "file")
store_read :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, S, T: ^wj.JSValue) -> bool {
	S^ = state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S^) { return false }
	if !check_store(ctx, S^, false, T) { wj.JS_FreeValue(ctx, S^); return false }
	return true
}

@(private = "file")
store_get_common :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, what: cstring, key_only: bool) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	if !arity(ctx, 1, argc, what, "IDBObjectStore") { return wj.EXCEPTION }
	T: wj.JSValue
	if !check_store(ctx, S, false, &T) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, T)
	return get_request(ctx, S, wj.NULL, T, this_val, key_only, argv[0], false)
}
store_get    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return store_get_common(ctx, this_val, argc, argv, "get", false) }
store_getKey :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return store_get_common(ctx, this_val, argc, argv, "getKey", true) }

store_count :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S, T: wj.JSValue
	if !store_read(ctx, this_val, &S, &T) { return wj.EXCEPTION }
	r := count_request(ctx, S, wj.NULL, T, this_val, wj.arg(argc, argv, 0))
	wj.JS_FreeValue(ctx, T)
	wj.JS_FreeValue(ctx, S)
	return r
}

// getAll (mode 2) / getAllKeys (mode 1)
@(private = "file")
store_get_all :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, mode: i32) -> wj.JSValue {
	S, T: wj.JSValue
	if !store_read(ctx, this_val, &S, &T) { return wj.EXCEPTION }
	defer { wj.JS_FreeValue(ctx, T); wj.JS_FreeValue(ctx, S) }
	a: List_Args
	if !list_args(ctx, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), &a) { return wj.EXCEPTION }
	r := get_all_request(ctx, S, wj.NULL, T, this_val, mode, &a)
	wj.JS_FreeValue(ctx, a.range)
	return r
}
store_getAll     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return store_get_all(ctx, this_val, argc, argv, 2) }
store_getAllKeys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return store_get_all(ctx, this_val, argc, argv, 1) }

store_getAllRecords :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	a: List_Args
	if !options_args(ctx, wj.arg(argc, argv, 0), &a) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, a.range)
	T: wj.JSValue
	if !check_store(ctx, S, false, &T) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, T)
	return get_all_request(ctx, S, wj.NULL, T, this_val, 3, &a)
}

@(private = "file")
store_open_cursor :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, key_only: bool) -> wj.JSValue {
	S, T: wj.JSValue
	if !store_read(ctx, this_val, &S, &T) { return wj.EXCEPTION }
	r := open_cursor(ctx, S, wj.NULL, T, this_val, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), key_only)
	wj.JS_FreeValue(ctx, T)
	wj.JS_FreeValue(ctx, S)
	return r
}
store_openCursor    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return store_open_cursor(ctx, this_val, argc, argv, false) }
store_openKeyCursor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return store_open_cursor(ctx, this_val, argc, argv, true) }

// The element of `list` whose `name` is nv (counted) and its position, or undefined and -1.
@(private = "file")
find_named :: proc "contextless" (ctx: ^wj.Context, list: wj.JSValue, nv: wj.JSValue) -> (wj.JSValue, i64) {
	n: i64
	wj.JS_GetLength(ctx, list, &n)
	for i in 0 ..< n {
		ix := wj.JS_GetPropertyInt64(ctx, list, i)
		if pstr_eq_val(ctx, ix, "name", nv) { return ix, i }
		wj.JS_FreeValue(ctx, ix)
	}
	return wj.UNDEFINED, -1
}

store_index :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	if !arity(ctx, 1, argc, "index", "IDBObjectStore") { return wj.EXCEPTION }
	nv := to_str(ctx, argv[0])   // NUL-safe JS string for the name lookup
	if wj.is_exception(nv) { return wj.EXCEPTION }
	meta := pget(ctx, S, "meta")
	T := pget(ctx, S, "tx")
	defer { wj.JS_FreeValue(ctx, nv); wj.JS_FreeValue(ctx, meta); wj.JS_FreeValue(ctx, T) }
	if pbool(ctx, meta, "deleted") { return throw_dom(ctx, "InvalidStateError", "The object store has been deleted.") }
	if pstr_eq(ctx, T, "state", "finished") { return throw_dom(ctx, "InvalidStateError", "The transaction has finished.") }
	indexes := pget(ctx, meta, "indexes")
	found, _ := find_named(ctx, indexes, nv)
	wj.JS_FreeValue(ctx, indexes)
	if wj.is_undefined(found) { return throw_dom(ctx, "NotFoundError", "The specified index was not found.") }
	r := index_for(ctx, S, found)
	wj.JS_FreeValue(ctx, found)
	return r
}

store_createIndex :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	if !arity(ctx, 2, argc, "createIndex", "IDBObjectStore") { return wj.EXCEPTION }
	nv := to_str(ctx, argv[0])   // NUL-safe JS string for the index name
	if wj.is_exception(nv) { return wj.EXCEPTION }
	kp: wj.JSValue
	if wj.JS_IsArray(argv[1]) {
		l: i64
		wj.JS_GetLength(ctx, argv[1], &l)
		kp = wj.JS_NewArray(ctx)
		for i in 0 ..< l {
			e := wj.JS_GetPropertyInt64(ctx, argv[1], i)
			wj.JS_SetPropertyInt64(ctx, kp, i, to_str(ctx, e))
			wj.JS_FreeValue(ctx, e)
		}
	} else {
		kp = to_str(ctx, argv[1])
	}
	unique, multi_entry: bool
	options := wj.arg(argc, argv, 2)
	if !wj.is_nullish(options) {
		unique = rsb(ctx, options, "unique")
		multi_entry = rsb(ctx, options, "multiEntry")
	}
	T := pget(ctx, S, "tx")
	meta := pget(ctx, S, "meta")
	defer { wj.JS_FreeValue(ctx, nv); wj.JS_FreeValue(ctx, kp); wj.JS_FreeValue(ctx, T); wj.JS_FreeValue(ctx, meta) }
	if !pstr_eq(ctx, T, "mode", "versionchange") { return throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction.") }
	if pbool(ctx, meta, "deleted") { return throw_dom(ctx, "InvalidStateError", "The object store has been deleted.") }
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "TransactionInactiveError", "The transaction is not active.") }
	indexes := pget(ctx, meta, "indexes")
	defer wj.JS_FreeValue(ctx, indexes)
	clash, _ := find_named(ctx, indexes, nv)
	if !wj.is_undefined(clash) { wj.JS_FreeValue(ctx, clash); return throw_dom(ctx, "ConstraintError", "An index with the specified name already exists.") }
	valid := call1(ctx, M.h_validPath, kp)
	ok := wj.JS_ToBool(ctx, valid) != 0
	wj.JS_FreeValue(ctx, valid)
	if !ok { return throw_dom(ctx, "SyntaxError", "The keyPath argument contains an invalid key path.") }
	if wj.JS_IsArray(kp) && multi_entry { return throw_dom(ctx, "InvalidAccessError", "The keyPath argument is an array and the multiEntry option is true.") }
	imeta := wj.JS_NewObject(ctx)
	set_own(ctx, imeta, "id", wj.new_int32(0))
	wj.JS_SetPropertyStr(ctx, imeta, "name", wj.JS_DupValue(ctx, nv))
	wj.JS_SetPropertyStr(ctx, imeta, "keyPath", frozen_path(ctx, kp))
	wj.JS_SetPropertyStr(ctx, imeta, "unique", wj.new_bool(unique))
	wj.JS_SetPropertyStr(ctx, imeta, "multiEntry", wj.new_bool(multi_entry))
	wj.JS_SetPropertyStr(ctx, imeta, "deleted", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, imeta, "ready", wj.FALSE)
	cur: i64
	wj.JS_GetLength(ctx, indexes, &cur)
	wj.JS_SetPropertyInt64(ctx, indexes, cur, wj.JS_DupValue(ctx, imeta))
	flags := (unique ? 1 : 0) | (multi_entry ? 2 : 0)
	d := [6]wj.JSValue{ T, meta, imeta, nv, kp, wj.new_int32(i32(flags)) }
	enqueue_internal(ctx, T, make_exec(ctx, EX_CREATE_INDEX, d[:]))
	r := index_for(ctx, S, imeta)
	wj.JS_FreeValue(ctx, imeta)
	return r
}

store_deleteIndex :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	S := state_of(ctx, M.storeState, this_val)
	if wj.is_exception(S) { return S }
	defer wj.JS_FreeValue(ctx, S)
	if !arity(ctx, 1, argc, "deleteIndex", "IDBObjectStore") { return wj.EXCEPTION }
	nv := to_str(ctx, argv[0])   // NUL-safe JS string for the name lookup
	if wj.is_exception(nv) { return wj.EXCEPTION }
	T := pget(ctx, S, "tx")
	meta := pget(ctx, S, "meta")
	defer { wj.JS_FreeValue(ctx, nv); wj.JS_FreeValue(ctx, T); wj.JS_FreeValue(ctx, meta) }
	if !pstr_eq(ctx, T, "mode", "versionchange") { return throw_dom(ctx, "InvalidStateError", "The database is not running a version change transaction.") }
	if pbool(ctx, meta, "deleted") { return throw_dom(ctx, "InvalidStateError", "The object store has been deleted.") }
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "TransactionInactiveError", "The transaction is not active.") }
	indexes := pget(ctx, meta, "indexes")
	imeta, at := find_named(ctx, indexes, nv)
	if at < 0 { wj.JS_FreeValue(ctx, indexes); return throw_dom(ctx, "NotFoundError", "The specified index was not found.") }
	splice_one(ctx, indexes, at)
	wj.JS_FreeValue(ctx, indexes)
	pset(ctx, imeta, "deleted", wj.TRUE)
	d := [3]wj.JSValue{ T, meta, imeta }
	enqueue_internal(ctx, T, make_exec(ctx, EX_DELETE_INDEX, d[:]))
	wj.JS_FreeValue(ctx, imeta)
	return wj.UNDEFINED
}

// ---- IDBIndex ----

@(private = "file")
index_meta_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	X := state_of(ctx, M.indexState, this_val)
	if wj.is_exception(X) { return X }
	meta := pget(ctx, X, "meta")
	v := pget(ctx, meta, field)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, X)
	return v
}

index_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return index_meta_field(ctx, this_val, "name") }

index_set_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, value: wj.JSValue) -> wj.JSValue {
	X := state_of(ctx, M.indexState, this_val)
	if wj.is_exception(X) { return X }
	// ToString(name) runs before any state check, as the spec and the old idb.js did (a throwing toString is observed
	// even on an inactive transaction). The name is kept as a JS string.
	nv := to_str(ctx, value)
	S := pget(ctx, X, "store")
	T := pget(ctx, S, "tx")
	meta := pget(ctx, X, "meta")
	smeta := pget(ctx, S, "meta")
	defer {
		wj.JS_FreeValue(ctx, nv); wj.JS_FreeValue(ctx, S); wj.JS_FreeValue(ctx, T)
		wj.JS_FreeValue(ctx, meta); wj.JS_FreeValue(ctx, smeta); wj.JS_FreeValue(ctx, X)
	}
	if wj.is_exception(nv) { return wj.EXCEPTION }
	if !pstr_eq(ctx, T, "mode", "versionchange") { return throw_dom(ctx, "InvalidStateError", "The index's name can only be changed in a version change transaction.") }
	if pbool(ctx, meta, "deleted") || pbool(ctx, smeta, "deleted") { return throw_dom(ctx, "InvalidStateError", "The index or its object store has been deleted.") }
	if !pstr_eq(ctx, T, "state", "active") { return throw_dom(ctx, "TransactionInactiveError", "The transaction is not active.") }
	if pstr_eq_val(ctx, meta, "name", nv) { return wj.UNDEFINED }
	indexes := pget(ctx, smeta, "indexes")
	n: i64
	wj.JS_GetLength(ctx, indexes, &n)
	clash := false
	for i: i64 = 0; i < n && !clash; i += 1 {
		ix := wj.JS_GetPropertyInt64(ctx, indexes, i)
		clash = !wj.same_ptr(ix, meta) && pstr_eq_val(ctx, ix, "name", nv)
		wj.JS_FreeValue(ctx, ix)
	}
	wj.JS_FreeValue(ctx, indexes)
	if clash { return throw_dom(ctx, "ConstraintError", "An index with the specified name already exists.") }
	pset(ctx, meta, "name", wj.JS_DupValue(ctx, nv))
	d := [4]wj.JSValue{ T, smeta, meta, nv }
	enqueue_internal(ctx, T, make_exec(ctx, EX_RENAME_INDEX, d[:]))
	return wj.UNDEFINED
}

index_get_objectStore :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	X := state_of(ctx, M.indexState, this_val)
	if wj.is_exception(X) { return X }
	S := pget(ctx, X, "store")
	w := pget(ctx, S, "wrapper")
	wj.JS_FreeValue(ctx, S)
	wj.JS_FreeValue(ctx, X)
	return w
}

index_get_keyPath :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	X := state_of(ctx, M.indexState, this_val)
	if wj.is_exception(X) { return X }
	meta := pget(ctx, X, "meta")
	kp := pget(ctx, meta, "keyPath")
	r := key_path_of(ctx, X, kp)
	wj.JS_FreeValue(ctx, kp)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, X)
	return r
}

@(private = "file")
index_flag :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	v := index_meta_field(ctx, this_val, field)
	if wj.is_exception(v) { return v }
	b := wj.JS_ToBool(ctx, v) != 0
	wj.JS_FreeValue(ctx, v)
	return wj.new_bool(b)
}
index_get_multiEntry :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return index_flag(ctx, this_val, "multiEntry") }
index_get_unique     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return index_flag(ctx, this_val, "unique") }

// An index method's states: the index X, its active transaction T, its store S and its metadata (all counted).
@(private = "file")
Index_Call :: struct { X, T, S, meta: wj.JSValue }

@(private = "file")
index_method :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, c: ^Index_Call) -> bool {
	c.X = state_of(ctx, M.indexState, this_val)
	if wj.is_exception(c.X) { return false }
	if !check_index(ctx, c.X, &c.T) { wj.JS_FreeValue(ctx, c.X); return false }
	c.S = pget(ctx, c.X, "store")
	c.meta = pget(ctx, c.X, "meta")
	return true
}
@(private = "file")
index_call_free :: proc "contextless" (ctx: ^wj.Context, c: ^Index_Call) {
	wj.JS_FreeValue(ctx, c.meta)
	wj.JS_FreeValue(ctx, c.S)
	wj.JS_FreeValue(ctx, c.T)
	wj.JS_FreeValue(ctx, c.X)
}

@(private = "file")
index_get_common :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, what: cstring, key_only: bool) -> wj.JSValue {
	if !arity(ctx, 1, argc, what, "IDBIndex") { return wj.EXCEPTION }
	c: Index_Call
	if !index_method(ctx, this_val, &c) { return wj.EXCEPTION }
	defer index_call_free(ctx, &c)
	return get_request(ctx, c.S, c.meta, c.T, this_val, key_only, argv[0], false)
}
index_get    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return index_get_common(ctx, this_val, argc, argv, "get", false) }
index_getKey :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return index_get_common(ctx, this_val, argc, argv, "getKey", true) }

index_count :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c: Index_Call
	if !index_method(ctx, this_val, &c) { return wj.EXCEPTION }
	defer index_call_free(ctx, &c)
	return count_request(ctx, c.S, c.meta, c.T, this_val, wj.arg(argc, argv, 0))
}

@(private = "file")
index_get_all :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, mode: i32) -> wj.JSValue {
	c: Index_Call
	if !index_method(ctx, this_val, &c) { return wj.EXCEPTION }
	defer index_call_free(ctx, &c)
	a: List_Args
	if !list_args(ctx, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), &a) { return wj.EXCEPTION }
	r := get_all_request(ctx, c.S, c.meta, c.T, this_val, mode, &a)
	wj.JS_FreeValue(ctx, a.range)
	return r
}
index_getAll     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return index_get_all(ctx, this_val, argc, argv, 2) }
index_getAllKeys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return index_get_all(ctx, this_val, argc, argv, 1) }

index_getAllRecords :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	X := state_of(ctx, M.indexState, this_val)
	if wj.is_exception(X) { return X }
	defer wj.JS_FreeValue(ctx, X)
	a: List_Args
	if !options_args(ctx, wj.arg(argc, argv, 0), &a) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, a.range)
	T: wj.JSValue
	if !check_index(ctx, X, &T) { return wj.EXCEPTION }
	S := pget(ctx, X, "store")
	meta := pget(ctx, X, "meta")
	r := get_all_request(ctx, S, meta, T, this_val, 3, &a)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, S)
	wj.JS_FreeValue(ctx, T)
	return r
}

@(private = "file")
index_open_cursor :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, key_only: bool) -> wj.JSValue {
	c: Index_Call
	if !index_method(ctx, this_val, &c) { return wj.EXCEPTION }
	defer index_call_free(ctx, &c)
	return open_cursor(ctx, c.S, c.meta, c.T, this_val, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), key_only)
}
index_openCursor    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return index_open_cursor(ctx, this_val, argc, argv, false) }
index_openKeyCursor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return index_open_cursor(ctx, this_val, argc, argv, true) }
