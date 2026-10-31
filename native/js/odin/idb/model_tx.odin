// model_tx.odin: the request / transaction state machine (queues, runNext, auto-commit, abort), connections and their
// metadata, the factory's methods, the exec closures (what each queued request does at the browser), records, requests'
// getters, object stores' and indexes' state, checks and request builders. Ported from web_idb_prelude.c (same names).
//
// A transaction T is an engine object kept in txState and in the `txs` Map by id; its fields are those of the old
// `newTransaction`. A queue entry is { R, exec } where `exec` is a native function with data (the old arrow function)
// carrying what it needs; it runs with `this` = T, returning the request's result or throwing a Failure.
package idb

import "../wj"

// the kinds of exec closures (magic of the native function)
EX_CREATE_STORE :: 1
EX_DELETE_STORE :: 2
EX_RENAME_STORE :: 3
EX_CREATE_INDEX :: 4
EX_DELETE_INDEX :: 5
EX_RENAME_INDEX :: 6
EX_GET          :: 7
EX_GET_ALL      :: 8
EX_COUNT        :: 9
EX_PUT          :: 10
EX_DELETE       :: 11
EX_CLEAR        :: 12
EX_CURSOR       :: 13

// make an exec closure with its captured JSValues (the first is always T)
make_exec :: proc "contextless" (ctx: ^wj.Context, kind: i32, data: []wj.JSValue) -> wj.JSValue {
	return wj.JS_NewCFunctionData(ctx, exec_closure, 0, kind, i32(len(data)), raw_data(data))
}

// reqWriter(T, op, store): a frame with the transaction id, the op byte, and (unless CREATE_STORE) the store id
req_writer :: proc "contextless" (ctx: ^wj.Context, w: ^Wr, T: wj.JSValue, op: u8, store: u64) {
	wr_uv(w, u64(pint(ctx, T, "id")))
	wr_u8(w, op)
	if op != REQ_CREATE_STORE { wr_uv(w, store) }
}

// newRequest(proto, source, tx): the request object and its state in reqState. Returns the state (counted); the
// wrapper is state.wrapper.
new_request :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue, source: wj.JSValue, tx: wj.JSValue) -> wj.JSValue {
	w := obj_create(ctx, proto)
	r := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, r, "wrapper", wj.JS_DupValue(ctx, w))
	wj.JS_SetPropertyStr(ctx, r, "readyState", wj.new_string(ctx, "pending"))
	wj.JS_SetPropertyStr(ctx, r, "result", wj.UNDEFINED)
	wj.JS_SetPropertyStr(ctx, r, "error", wj.NULL)
	wj.JS_SetPropertyStr(ctx, r, "source", wj.JS_DupValue(ctx, source))
	wj.JS_SetPropertyStr(ctx, r, "tx", wj.JS_DupValue(ctx, tx))
	wj.JS_SetPropertyStr(ctx, r, "cursor", wj.NULL)
	wm_set(ctx, M.reqState, w, r)
	wj.JS_FreeValue(ctx, w)
	return r
}

// enqueue(T, R, exec): a queue entry (R null: an internal operation with no request, e.g. store / index creation).
// Takes `exec`.
enqueue :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, R: wj.JSValue, exec: wj.JSValue) {
	q := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, q, "R", wj.JS_DupValue(ctx, R))
	wj.JS_SetPropertyStr(ctx, q, "exec", exec)
	queue := pget(ctx, T, "queue")
	n: i64
	wj.JS_GetLength(ctx, queue, &n)
	wj.JS_SetPropertyInt64(ctx, queue, n, q)
	wj.JS_FreeValue(ctx, queue)
	if pbool(ctx, T, "started") { process_next(ctx, T) }
}
enqueue_internal :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, exec: wj.JSValue) { enqueue(ctx, T, wj.NULL, exec) }

// a task closure: magic selects the kind of posted work
TASK_RUN_NEXT     :: 1
TASK_OPEN_ERROR   :: 2
TASK_ABORT_REQ    :: 3
TASK_ABORT_FINISH :: 4

post_closure :: proc "contextless" (ctx: ^wj.Context, kind: i32, v: wj.JSValue) {
	v := v
	post_task(ctx, wj.JS_NewCFunctionData(ctx, task_closure, 0, kind, 1, &v))
}

@(private = "file")
queue_length :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) -> i64 {
	queue := pget(ctx, T, "queue")
	n: i64
	wj.JS_GetLength(ctx, queue, &n)
	wj.JS_FreeValue(ctx, queue)
	return n
}

// processNext(T): if idle and started, post runNext
process_next :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) {
	if pbool(ctx, T, "busy") || !pbool(ctx, T, "started") || pbool(ctx, T, "dead") { return }
	if queue_length(ctx, T) == 0 { return }
	pset(ctx, T, "busy", wj.TRUE)
	post_closure(ctx, TASK_RUN_NEXT, T)
}

// runNext(T): run the next queue entry, fire its event, advance the state machine
run_next :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) {
	if pbool(ctx, T, "dead") { return }
	queue := pget(ctx, T, "queue")
	n: i64
	wj.JS_GetLength(ctx, queue, &n)
	if n == 0 { wj.JS_FreeValue(ctx, queue); pset(ctx, T, "busy", wj.FALSE); maybe_commit(ctx, T); return }
	q := method_call(ctx, queue, "shift", nil)
	wj.JS_FreeValue(ctx, queue)
	R := wj.JS_GetPropertyStr(ctx, q, "R")
	exec := wj.JS_GetPropertyStr(ctx, q, "exec")
	defer { wj.JS_FreeValue(ctx, exec); wj.JS_FreeValue(ctx, R); wj.JS_FreeValue(ctx, q) }
	if wj.is_null(R) {   // an internal operation: no request, no event
		r := wj.JS_Call(ctx, exec, T, 0, nil)
		if wj.is_exception(r) {
			e := wj.JS_GetException(ctx)
			if code, failed := is_failure(ctx, e); failed {
				msg := wj.JS_GetPropertyStr(ctx, e, "message")
				ms := wj.is_undefined(msg) ? nil : wj.to_cstring(ctx, msg)
				fv := fail_value(ctx, code, ms)
				if ms != nil { wj.free_cstring(ctx, ms) }
				wj.JS_FreeValue(ctx, msg)
				wj.JS_FreeValue(ctx, e)
				abort_transaction(ctx, T, fv, code, true)
				wj.JS_FreeValue(ctx, fv)
				return
			}
			// not a Failure: report it (the browser's event loop handles it)
			host_report(ctx, e)
		} else {
			wj.JS_FreeValue(ctx, r)
		}
		pset(ctx, T, "busy", wj.FALSE)
		if queue_length(ctx, T) > 0 { process_next(ctx, T) } else { maybe_commit(ctx, T) }
		return
	}
	ok := true
	err_code: i32
	err_msg := wj.UNDEFINED   // the Failure's message (a string) or undefined
	defer wj.JS_FreeValue(ctx, err_msg)
	value := wj.JS_Call(ctx, exec, T, 0, nil)
	if wj.is_exception(value) {
		e := wj.JS_GetException(ctx)
		if code, failed := is_failure(ctx, e); failed {
			ok = false
			err_code = code
			err_msg = wj.JS_GetPropertyStr(ctx, e, "message")
			wj.JS_FreeValue(ctx, e)
		} else {
			host_report(ctx, e)   // unexpected: report and treat as no value
		}
		value = wj.UNDEFINED
	}
	defer wj.JS_FreeValue(ctx, value)
	pstr(ctx, R, "readyState", "done")
	if !pstr_eq(ctx, T, "state", "committing") { pstr(ctx, T, "state", "active") }
	set_add(ctx, M.activeSet, T)
	arm_cleanup(ctx)
	Rw := wj.JS_GetPropertyStr(ctx, R, "wrapper")
	defer wj.JS_FreeValue(ctx, Rw)
	if ok {
		pset(ctx, R, "result", wj.JS_DupValue(ctx, value))
		pset(ctx, R, "error", wj.NULL)
		outcome := dispatch(ctx, Rw, plain_event(ctx, "success", false, false))
		pset(ctx, T, "busy", wj.FALSE)
		if outcome.threw && !pstr_eq(ctx, T, "state", "committing") {
			ab := dom_ex(ctx, "AbortError", "An exception was thrown by an event handler.")
			abort_transaction(ctx, T, ab, E_ABORTED, true)
			wj.JS_FreeValue(ctx, ab)
			return
		}
	} else {
		ms := wj.is_undefined(err_msg) ? nil : wj.to_cstring(ctx, err_msg)
		err := fail_value(ctx, err_code, ms)
		if ms != nil { wj.free_cstring(ctx, ms) }
		pset(ctx, R, "result", wj.UNDEFINED)
		pset(ctx, R, "error", wj.JS_DupValue(ctx, err))
		outcome := dispatch(ctx, Rw, plain_event(ctx, "error", true, true))
		pset(ctx, T, "busy", wj.FALSE)
		if outcome.threw {
			ab := dom_ex(ctx, "AbortError", "An exception was thrown by an event handler.")
			abort_transaction(ctx, T, ab, E_ABORTED, true)
			wj.JS_FreeValue(ctx, ab)
			wj.JS_FreeValue(ctx, err)
			return
		}
		if !outcome.canceled {
			abort_transaction(ctx, T, err, err_code, true)
			wj.JS_FreeValue(ctx, err)
			return
		}
		wj.JS_FreeValue(ctx, err)
	}
	if pstr_eq(ctx, T, "state", "active") || pstr_eq(ctx, T, "state", "inactive") || pstr_eq(ctx, T, "state", "committing") {
		process_next(ctx, T)
	}
}

// maybeCommit(T): send the commit when the transaction is done with its queue
maybe_commit :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) {
	if pbool(ctx, T, "dead") || pbool(ctx, T, "commitSent") || !pbool(ctx, T, "started") { return }
	if !pstr_eq(ctx, T, "state", "inactive") && !pstr_eq(ctx, T, "state", "committing") { return }
	if queue_length(ctx, T) > 0 || pbool(ctx, T, "busy") { return }
	pset(ctx, T, "commitSent", wj.TRUE)
	pstr(ctx, T, "state", "committing")
	w := Wr{ ctx = ctx }
	wr_uv(&w, u64(pint(ctx, T, "id")))
	rep := host_call1(ctx, OP_COMMIT, wr_u8array(ctx, &w))
	wr_free(&w)
	if reply_status(ctx, rep) != 0 { pset(ctx, T, "commitSent", wj.FALSE) }   // already aborted at the browser
	wj.JS_FreeValue(ctx, rep)
}

task_closure :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	switch magic {
	case TASK_RUN_NEXT:     run_next(ctx, data[0])
	case TASK_OPEN_ERROR:   open_error(ctx, data[0], E_UNKNOWN)   // a deleted bucket's open
	case TASK_ABORT_REQ:    task_run_abort_req(ctx, data[0])
	case TASK_ABORT_FINISH: task_run_abort_finish(ctx, data[0])
	}
	return wj.UNDEFINED
}

// ---- connections, metadata and the factory ----

// A store's or an index's name, key path (packed) and id of a metadata frame.
@(private = "file")
read_named :: proc "contextless" (ctx: ^wj.Context, r: ^Rd, obj: wj.JSValue) {
	set_own(ctx, obj, "id", wj.new_int64(ctx, i64(rd_uv(r))))
	wj.JS_SetPropertyStr(ctx, obj, "name", wj.string_of_wtf8(ctx, rd_bytes(r)))
	pr := Rd{ p = rd_bytes(r) }
	wj.JS_SetPropertyStr(ctx, obj, "keyPath", unpack_path(ctx, &pr))
}

// readMeta(rd): { version, stores: [ { id, name, keyPath, autoIncrement, indexes, hostIndexes, deleted, ready } ] }
read_meta :: proc "contextless" (ctx: ^wj.Context, r: ^Rd) -> wj.JSValue {
	meta := wj.JS_NewObject(ctx)
	version := rd_uv(r)
	wj.JS_SetPropertyStr(ctx, meta, "version", wj.new_int64(ctx, i64(version)))
	stores := wj.JS_NewArray(ctx)
	n := rd_uv(r)
	for i: u64 = 0; i < n && !r.bad; i += 1 {
		s := wj.JS_NewObject(ctx)
		read_named(ctx, r, s)
		wj.JS_SetPropertyStr(ctx, s, "autoIncrement", wj.new_bool(rd_u8(r) & 1 != 0))
		indexes := wj.JS_NewArray(ctx)
		host_indexes := wj.JS_NewArray(ctx)
		m := rd_uv(r)
		for j: u64 = 0; j < m && !r.bad; j += 1 {
			ix := wj.JS_NewObject(ctx)
			read_named(ctx, r, ix)
			f := rd_u8(r)
			wj.JS_SetPropertyStr(ctx, ix, "unique", wj.new_bool(f & 1 != 0))
			wj.JS_SetPropertyStr(ctx, ix, "multiEntry", wj.new_bool(f & 2 != 0))
			wj.JS_SetPropertyStr(ctx, ix, "deleted", wj.FALSE)
			wj.JS_SetPropertyStr(ctx, ix, "ready", wj.TRUE)
			wj.JS_SetPropertyInt64(ctx, indexes, i64(j), wj.JS_DupValue(ctx, ix))
			wj.JS_SetPropertyInt64(ctx, host_indexes, i64(j), ix)
		}
		wj.JS_SetPropertyStr(ctx, s, "indexes", indexes)
		wj.JS_SetPropertyStr(ctx, s, "hostIndexes", host_indexes)
		wj.JS_SetPropertyStr(ctx, s, "deleted", wj.FALSE)
		wj.JS_SetPropertyStr(ctx, s, "ready", wj.TRUE)
		wj.JS_SetPropertyInt64(ctx, stores, i64(i), s)
	}
	wj.JS_SetPropertyStr(ctx, meta, "stores", stores)
	return meta
}

// updateNames(c): set the connection's objectStoreNames list from its stores
update_names :: proc "contextless" (ctx: ^wj.Context, c: wj.JSValue) {
	stores := pget(ctx, c, "stores")
	names := sorted_names(ctx, stores, "name")
	list := pget(ctx, c, "names")
	count: i64
	wj.JS_GetLength(ctx, names, &count)
	set_list(ctx, list, names, count)
	wj.JS_FreeValue(ctx, list)
	wj.JS_FreeValue(ctx, names)
	wj.JS_FreeValue(ctx, stores)
}

// newConnection(id, name, meta): the IDBDatabase and its state in dbState and conns. Returns the connection state.
new_connection :: proc "contextless" (ctx: ^wj.Context, id: u64, name: wj.JSValue, meta: wj.JSValue) -> wj.JSValue {
	db := obj_create(ctx, M.proto_IDBDatabase)
	et_init(ctx, db)
	c := wj.JS_NewObject(ctx)
	set_own(ctx, c, "id", wj.new_int64(ctx, i64(id)))
	wj.JS_SetPropertyStr(ctx, c, "name", wj.JS_DupValue(ctx, name))
	wj.JS_SetPropertyStr(ctx, c, "version", wj.JS_GetPropertyStr(ctx, meta, "version"))
	wj.JS_SetPropertyStr(ctx, c, "wrapper", wj.JS_DupValue(ctx, db))
	wj.JS_SetPropertyStr(ctx, c, "stores", wj.JS_GetPropertyStr(ctx, meta, "stores"))
	wj.JS_SetPropertyStr(ctx, c, "closePending", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, c, "closed", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, c, "upgradeTx", wj.NULL)
	wj.JS_SetPropertyStr(ctx, c, "txCount", wj.new_int32(0))
	// names = makeList(stores.map(s => s.name).sort())
	stores := pget(ctx, c, "stores")
	names := sorted_names(ctx, stores, "name")
	wj.JS_SetPropertyStr(ctx, c, "names", make_list(ctx, names))
	wj.JS_FreeValue(ctx, names)
	wj.JS_FreeValue(ctx, stores)
	wm_set(ctx, M.dbState, db, c)
	idv := wj.new_int64(ctx, i64(id))
	map_set(ctx, M.conns, idv, c)
	wj.JS_FreeValue(ctx, idv)
	wj.JS_FreeValue(ctx, db)
	return c
}

// openError(req, code): fail an open/delete request
open_error :: proc "contextless" (ctx: ^wj.Context, req: wj.JSValue, code: i32) {
	pstr(ctx, req, "readyState", "done")
	pset(ctx, req, "result", wj.UNDEFINED)
	pset(ctx, req, "error", fail_value(ctx, code, nil))
	pset(ctx, req, "tx", wj.NULL)
	w := pget(ctx, req, "wrapper")
	dispatch(ctx, w, plain_event(ctx, "error", true, true))
	wj.JS_FreeValue(ctx, w)
}

// The factory's state and its bucket's name as a JS string (counted both). EXCEPTION on the wrong receiver.
@(private = "file")
factory_bucket :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> (F: wj.JSValue, bucket: wj.JSValue) {
	F = state_of(ctx, M.factoryState, this_val)
	if wj.is_exception(F) { return F, wj.UNDEFINED }
	b := wj.JS_GetPropertyStr(ctx, F, "bucket")
	bucket = wj.JS_ToString(ctx, b)
	wj.JS_FreeValue(ctx, b)
	return
}

// The id after the status byte of a reply.
@(private = "file")
reply_id :: proc "contextless" (p: []u8) -> u64 {
	r := Rd{ p = p, pos = 1 }
	return rd_uv(&r)
}

factory_open :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	F, bucket := factory_bucket(ctx, this_val)
	if wj.is_exception(F) { return F }
	defer { wj.JS_FreeValue(ctx, F); wj.JS_FreeValue(ctx, bucket) }
	if !arity(ctx, 1, argc, "open", "IDBFactory") { return wj.EXCEPTION }
	name_v := to_str(ctx, argv[0])
	defer wj.JS_FreeValue(ctx, name_v)
	v: u64
	has: u8
	if argc > 1 && !wj.is_undefined(argv[1]) {
		x: f64
		wj.JS_ToFloat64(ctx, &x, argv[1])
		if wj.is_nan(x) || wj.is_inf(x) || x < 0 || x > MAX_UV { return type_error(ctx, "Failed to execute 'open' on 'IDBFactory': The version provided is out of range.") }
		v = u64(x)
		if v == 0 { return type_error(ctx, "Failed to execute 'open' on 'IDBFactory': The version provided must not be 0.") }
		has = 1
	}
	w := Wr{ ctx = ctx }
	wr_jsstr(ctx, &w, name_v)
	wr_uv(&w, v)
	wr_u8(&w, has)
	wr_jsstr(ctx, &w, bucket)
	rep := host_call1(ctx, OP_OPEN, wr_u8array(ctx, &w))
	wr_free(&w)
	// the host call throws for an opaque origin or disabled storage (SecurityError): keep that exception, don't let
	// reply_bytes replace it with a "not a buffer source" TypeError
	if wj.is_exception(rep) { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, rep)
	rp, ok := reply_bytes(ctx, rep)
	if !ok { return wj.EXCEPTION }
	status := len(rp) > 0 ? i32(rp[0]) : 0
	bucketed := !is_empty_string(ctx, bucket)
	if status != 0 && !(bucketed && status == E_UNKNOWN) { return throw_fail(ctx, status, nil) }
	reqs := new_request(ctx, M.proto_IDBOpenDBRequest, wj.NULL, wj.NULL)
	defer wj.JS_FreeValue(ctx, reqs)
	pset(ctx, reqs, "name", wj.JS_DupValue(ctx, name_v))
	wrapper := pget(ctx, reqs, "wrapper")
	if status != 0 {   // the bucket was deleted: the request fails on a task
		post_closure(ctx, TASK_OPEN_ERROR, reqs)
	} else {
		idv := wj.new_int64(ctx, i64(reply_id(rp)))
		map_set(ctx, M.openReqs, idv, reqs)
		wj.JS_FreeValue(ctx, idv)
	}
	return wrapper
}

// a JS string is ""
is_empty_string :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue) -> bool {
	n: i64
	wj.JS_GetLength(ctx, s, &n)
	return n == 0
}

factory_delete_database :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	F, bucket := factory_bucket(ctx, this_val)
	if wj.is_exception(F) { return F }
	defer { wj.JS_FreeValue(ctx, F); wj.JS_FreeValue(ctx, bucket) }
	if !arity(ctx, 1, argc, "deleteDatabase", "IDBFactory") { return wj.EXCEPTION }
	name_v := to_str(ctx, argv[0])
	defer wj.JS_FreeValue(ctx, name_v)
	w := Wr{ ctx = ctx }
	wr_jsstr(ctx, &w, name_v)
	wr_jsstr(ctx, &w, bucket)
	rep := host_call1(ctx, OP_DELETE, wr_u8array(ctx, &w))
	wr_free(&w)
	if wj.is_exception(rep) { return wj.EXCEPTION }   // opaque origin: keep the SecurityError
	defer wj.JS_FreeValue(ctx, rep)
	rp, ok := reply_bytes(ctx, rep)
	if !ok { return wj.EXCEPTION }
	if len(rp) > 0 && rp[0] != 0 { return throw_fail(ctx, i32(rp[0]), nil) }
	reqs := new_request(ctx, M.proto_IDBOpenDBRequest, wj.NULL, wj.NULL)
	defer wj.JS_FreeValue(ctx, reqs)
	pset(ctx, reqs, "isDelete", wj.TRUE)
	idv := wj.new_int64(ctx, i64(reply_id(rp)))
	map_set(ctx, M.openReqs, idv, reqs)
	wj.JS_FreeValue(ctx, idv)
	return pget(ctx, reqs, "wrapper")
}

factory_databases :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	F, bucket := factory_bucket(ctx, this_val)
	if wj.is_exception(F) { return wj.web_promise_reject_pending(ctx) }
	defer wj.JS_FreeValue(ctx, F)
	w := Wr{ ctx = ctx }
	wr_jsstr(ctx, &w, bucket)
	wj.JS_FreeValue(ctx, bucket)
	rep := host_call1(ctx, OP_LIST, wr_u8array(ctx, &w))
	wr_free(&w)
	// opaque origin: the host threw a SecurityError; databases() returns a promise, so reject with it
	if wj.is_exception(rep) { return wj.web_promise_reject_pending(ctx) }
	defer wj.JS_FreeValue(ctx, rep)
	rp, ok := reply_bytes(ctx, rep)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	if len(rp) > 0 && rp[0] != 0 { return wj.web_promise_rejected(ctx, fail_value(ctx, i32(rp[0]), nil)) }
	funcs: [2]wj.JSValue
	promise := wj.web_promise_new(ctx, &funcs[0])
	entry := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, entry, "resolve", funcs[0])
	wj.JS_SetPropertyStr(ctx, entry, "reject", funcs[1])
	idv := wj.new_int64(ctx, i64(reply_id(rp)))
	map_set(ctx, M.listReqs, idv, entry)
	wj.JS_FreeValue(ctx, idv)
	wj.JS_FreeValue(ctx, entry)
	return promise
}

factory_cmp :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	F := state_of(ctx, M.factoryState, this_val)
	if wj.is_exception(F) { return F }
	wj.JS_FreeValue(ctx, F)
	if !arity(ctx, 2, argc, "cmp", "IDBFactory") { return wj.EXCEPTION }
	a := key_of(ctx, argv[0])
	if wj.is_exception(a) { return a }
	if wj.is_null(a) { return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
	b := key_of(ctx, argv[1])
	if wj.is_exception(b) { wj.JS_FreeValue(ctx, a); return b }
	if wj.is_null(b) { wj.JS_FreeValue(ctx, a); return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
	c := cmp_bytes(ctx, a, b)
	wj.JS_FreeValue(ctx, a)
	wj.JS_FreeValue(ctx, b)
	return wj.new_int32(c)
}

// ---- the exec closures: the native request helpers of web_idb_native.odin (host.execGet...) ----

// host.execX(args...) with `this` = the host object; the numbers are made here and freed after.
@(private = "file")
h_exec :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, args: []wj.JSValue) -> wj.JSValue {
	return wj.JS_Call(ctx, fn, M.host, i32(len(args)), raw_data(args))
}
@(private = "file")
num :: #force_inline proc "contextless" (ctx: ^wj.Context, v: u64) -> wj.JSValue { return wj.new_int64(ctx, i64(v)) }

// EXEC a frame built by `w` and read the reply through expectOk; the reader borrows the reply, kept alive in `keep`
// (JS_FreeValue it). False with a Failure thrown.
exec_frame :: proc "contextless" (ctx: ^wj.Context, w: ^Wr, out: ^Rd, keep: ^wj.JSValue) -> bool {
	if w.oom { wr_free(w); wj.JS_ThrowOutOfMemory(ctx); return false }
	rep := host_call1(ctx, OP_EXEC, wr_u8array(ctx, w))
	wr_free(w)
	if wj.is_exception(rep) { return false }
	if !expect_ok(ctx, rep, out) { wj.JS_FreeValue(ctx, rep); return false }
	keep^ = rep
	return true
}

// snapIndexKeys(S_meta, value): [[ix, keys], ...] over S.meta.indexes
snap_index_keys :: proc "contextless" (ctx: ^wj.Context, meta: wj.JSValue, value: wj.JSValue) -> wj.JSValue {
	out := wj.JS_NewArray(ctx)
	indexes := wj.JS_GetPropertyStr(ctx, meta, "indexes")
	n: i64
	wj.JS_GetLength(ctx, indexes, &n)
	for i in 0 ..< n {
		ix := wj.JS_GetPropertyInt64(ctx, indexes, i)
		kp := wj.JS_GetPropertyStr(ctx, ix, "keyPath")
		keys := index_keys(ctx, value, kp, pbool(ctx, ix, "multiEntry"))
		wj.JS_FreeValue(ctx, kp)
		pair := wj.JS_NewArray(ctx)
		wj.JS_SetPropertyUint32(ctx, pair, 0, ix)
		wj.JS_SetPropertyUint32(ctx, pair, 1, wj.is_exception(keys) ? wj.JS_NewArray(ctx) : keys)
		wj.JS_SetPropertyInt64(ctx, out, i, pair)
	}
	wj.JS_FreeValue(ctx, indexes)
	return out
}

// indexKeyList(S_meta, snap, bytes): [index id, key, index id, key...] for the host's current indexes (hostIndexes)
index_key_list :: proc "contextless" (ctx: ^wj.Context, meta: wj.JSValue, snap: wj.JSValue, bytes: wj.JSValue) -> wj.JSValue {
	list := wj.JS_NewArray(ctx)
	k: u32
	clone := wj.UNDEFINED
	host_ix := wj.JS_GetPropertyStr(ctx, meta, "hostIndexes")
	hn, sn: i64
	wj.JS_GetLength(ctx, host_ix, &hn)
	wj.JS_GetLength(ctx, snap, &sn)
	for i in 0 ..< hn {
		ix := wj.JS_GetPropertyInt64(ctx, host_ix, i)
		keys := wj.UNDEFINED
		for j in 0 ..< sn {
			e := wj.JS_GetPropertyInt64(ctx, snap, j)
			e0 := wj.JS_GetPropertyUint32(ctx, e, 0)
			same := wj.same_ptr(e0, ix)
			wj.JS_FreeValue(ctx, e0)
			if same { keys = wj.JS_GetPropertyUint32(ctx, e, 1); wj.JS_FreeValue(ctx, e); break }
			wj.JS_FreeValue(ctx, e)
		}
		if wj.is_undefined(keys) {
			if wj.is_undefined(clone) { clone = deserialize(ctx, bytes) }
			kp := wj.JS_GetPropertyStr(ctx, ix, "keyPath")
			keys = index_keys(ctx, clone, kp, pbool(ctx, ix, "multiEntry"))
			wj.JS_FreeValue(ctx, kp)
		}
		kn: i64
		wj.JS_GetLength(ctx, keys, &kn)
		idv := wj.JS_GetPropertyStr(ctx, ix, "id")
		for j in 0 ..< kn {
			wj.JS_SetPropertyUint32(ctx, list, k, wj.JS_DupValue(ctx, idv))
			wj.JS_SetPropertyUint32(ctx, list, k + 1, wj.JS_GetPropertyInt64(ctx, keys, j))
			k += 2
		}
		wj.JS_FreeValue(ctx, idv)
		wj.JS_FreeValue(ctx, keys)
		wj.JS_FreeValue(ctx, ix)
	}
	wj.JS_FreeValue(ctx, host_ix)
	if !wj.is_undefined(clone) { wj.JS_FreeValue(ctx, clone) }
	return list
}

// The id of a metadata object (0 for null).
@(private = "file")
meta_id :: proc "contextless" (ctx: ^wj.Context, meta: wj.JSValue) -> u64 { return wj.is_null(meta) ? 0 : u64(pint(ctx, meta, "id")) }

// A name (a JS string) into a frame.
@(private = "file")
wr_name :: proc "contextless" (ctx: ^wj.Context, w: ^Wr, v: wj.JSValue) { wr_jsstr(ctx, w, v) }

// A key path packed into a frame (length-prefixed).
@(private = "file")
wr_path :: proc "contextless" (ctx: ^wj.Context, w: ^Wr, kp: wj.JSValue) {
	packed := pack_path(ctx, kp)
	pp, _ := reply_bytes(ctx, packed)
	wr_bytes(w, pp)
	wj.JS_FreeValue(ctx, packed)
}

// An internal operation's frame sent: undefined, or EXCEPTION with the Failure thrown.
@(private = "file")
exec_simple :: proc "contextless" (ctx: ^wj.Context, w: ^Wr) -> wj.JSValue {
	r: Rd
	keep: wj.JSValue
	if !exec_frame(ctx, w, &r, &keep) { return wj.EXCEPTION }
	wj.JS_FreeValue(ctx, keep)
	return wj.UNDEFINED
}

// The exec bodies. Captured data by kind (T is always data[0]):
//   EX_GET:      [T, storeMeta, indexMeta|null, rangeBytes, keyOnly]            -> execGet
//   EX_GET_ALL:  [T, storeMeta, indexMeta|null, rangeBytes, mode, flags, limit] -> execGetAll (+records for mode 3)
//   EX_COUNT:    [T, storeMeta, indexMeta|null, rangeBytes]                      -> execCount
//   EX_PUT:      [T, storeMeta, flags, keyBytes|null, valueBytes, kp|null, generate, snapshot|null]
//   EX_DELETE:   [T, storeMeta, rangeBytes]                                      -> execDelete
//   EX_CLEAR:    [T, storeMeta]                                                  -> execClear
//   EX_CURSOR:   [T, C, target|null, targetPk|null, count]                       -> cursorExec
//   EX_CREATE_STORE: [T, meta, name, keyPath, autoIncrement]
//   EX_DELETE_STORE: [T, meta]
//   EX_RENAME_STORE: [T, meta, name]
//   EX_CREATE_INDEX: [T, S_meta, meta, name, keyPath, flags]
//   EX_DELETE_INDEX: [T, S_meta, meta]
//   EX_RENAME_INDEX: [T, S_meta, meta, name]
exec_closure :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	T := data[0]
	txid := u64(pint(ctx, T, "id"))
	switch magic {
	case EX_GET:
		a := [5]wj.JSValue{ num(ctx, txid), num(ctx, meta_id(ctx, data[1])), num(ctx, meta_id(ctx, data[2])), data[3], wj.new_bool(wj.JS_ToBool(ctx, data[4]) != 0) }
		return h_exec(ctx, M.h_execGet, a[:])
	case EX_GET_ALL:
		mode, flags: i32
		wj.JS_ToInt32(ctx, &mode, data[4])
		wj.JS_ToInt32(ctx, &flags, data[5])
		l: i64
		wj.JS_ToInt64(ctx, &l, data[6])
		a := [7]wj.JSValue{ num(ctx, txid), num(ctx, meta_id(ctx, data[1])), num(ctx, meta_id(ctx, data[2])), data[3], wj.new_int32(mode), wj.new_int32(flags), num(ctx, u64(u32(l))) }
		out := h_exec(ctx, M.h_execGetAll, a[:])
		if wj.is_exception(out) || mode != 3 { return out }
		records := wj.JS_NewArray(ctx)
		n: i64
		wj.JS_GetLength(ctx, out, &n)
		k: u32
		for i: i64 = 0; i + 2 < n; i += 3 {
			key := wj.JS_GetPropertyInt64(ctx, out, i)
			pk := wj.JS_GetPropertyInt64(ctx, out, i + 1)
			value := wj.JS_GetPropertyInt64(ctx, out, i + 2)
			wj.JS_SetPropertyUint32(ctx, records, k, make_record(ctx, key, pk, value))
			k += 1
			wj.JS_FreeValue(ctx, key)
			wj.JS_FreeValue(ctx, pk)
			wj.JS_FreeValue(ctx, value)
		}
		wj.JS_FreeValue(ctx, out)
		return records
	case EX_COUNT:
		a := [4]wj.JSValue{ num(ctx, txid), num(ctx, meta_id(ctx, data[1])), num(ctx, meta_id(ctx, data[2])), data[3] }
		return h_exec(ctx, M.h_execCount, a[:])
	case EX_DELETE:
		a := [3]wj.JSValue{ num(ctx, txid), num(ctx, meta_id(ctx, data[1])), data[2] }
		r := h_exec(ctx, M.h_execDelete, a[:])
		if wj.is_exception(r) { return r }
		wj.JS_FreeValue(ctx, r)
		return wj.UNDEFINED
	case EX_CLEAR:
		a := [2]wj.JSValue{ num(ctx, txid), num(ctx, meta_id(ctx, data[1])) }
		r := h_exec(ctx, M.h_execClear, a[:])
		if wj.is_exception(r) { return r }
		wj.JS_FreeValue(ctx, r)
		return wj.UNDEFINED
	case EX_PUT:
		return exec_put(ctx, T, txid, data)
	case EX_CURSOR:
		c: i64
		wj.JS_ToInt64(ctx, &c, data[4])
		return cursor_exec(ctx, data[1], data[2], data[3], u32(c))
	case EX_CREATE_STORE:
		meta := data[1]
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_CREATE_STORE, 0)
		wr_name(ctx, &w, data[2])
		wr_path(ctx, &w, data[3])
		wr_u8(&w, wj.JS_ToBool(ctx, data[4]) != 0 ? 1 : 0)
		r: Rd
		keep: wj.JSValue
		if !exec_frame(ctx, &w, &r, &keep) { return wj.EXCEPTION }
		pset(ctx, meta, "id", wj.new_int64(ctx, i64(rd_uv(&r))))
		pset(ctx, meta, "ready", wj.TRUE)
		wj.JS_FreeValue(ctx, keep)
		return wj.UNDEFINED
	case EX_DELETE_STORE:
		meta := data[1]
		if !pbool(ctx, meta, "ready") { return wj.UNDEFINED }
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_DELETE_STORE, meta_id(ctx, meta))
		return exec_simple(ctx, &w)
	case EX_RENAME_STORE:
		meta := data[1]
		if !pbool(ctx, meta, "ready") { return wj.UNDEFINED }
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_RENAME_STORE, meta_id(ctx, meta))
		wr_name(ctx, &w, data[2])
		return exec_simple(ctx, &w)
	case EX_CREATE_INDEX:
		s_meta, meta := data[1], data[2]
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_CREATE_INDEX, meta_id(ctx, s_meta))
		wr_name(ctx, &w, data[3])
		wr_path(ctx, &w, data[4])
		flags: i32
		wj.JS_ToInt32(ctx, &flags, data[5])
		wr_u8(&w, u8(flags))
		r: Rd
		keep: wj.JSValue
		if !exec_frame(ctx, &w, &r, &keep) { return wj.EXCEPTION }
		pset(ctx, meta, "id", wj.new_int64(ctx, i64(rd_uv(&r))))
		wj.JS_FreeValue(ctx, keep)
		populate_index(ctx, T, s_meta, meta)
		if wj.JS_HasException(ctx) { return wj.EXCEPTION }
		pset(ctx, meta, "ready", wj.TRUE)
		host_ix := wj.JS_GetPropertyStr(ctx, s_meta, "hostIndexes")
		hn: i64
		wj.JS_GetLength(ctx, host_ix, &hn)
		wj.JS_SetPropertyInt64(ctx, host_ix, hn, wj.JS_DupValue(ctx, meta))
		wj.JS_FreeValue(ctx, host_ix)
		return wj.UNDEFINED
	case EX_DELETE_INDEX:
		s_meta, meta := data[1], data[2]
		if !pbool(ctx, meta, "ready") { return wj.UNDEFINED }
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_DELETE_INDEX, meta_id(ctx, s_meta))
		wr_uv(&w, meta_id(ctx, meta))
		if wj.is_exception(exec_simple(ctx, &w)) { return wj.EXCEPTION }
		// remove meta from hostIndexes
		host_ix := wj.JS_GetPropertyStr(ctx, s_meta, "hostIndexes")
		hn: i64
		wj.JS_GetLength(ctx, host_ix, &hn)
		for i in 0 ..< hn {
			e := wj.JS_GetPropertyInt64(ctx, host_ix, i)
			same := wj.same_ptr(e, meta)
			wj.JS_FreeValue(ctx, e)
			if same { splice_one(ctx, host_ix, i); break }
		}
		wj.JS_FreeValue(ctx, host_ix)
		return wj.UNDEFINED
	case EX_RENAME_INDEX:
		s_meta, meta := data[1], data[2]
		if !pbool(ctx, meta, "ready") { return wj.UNDEFINED }
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_RENAME_INDEX, meta_id(ctx, s_meta))
		wr_uv(&w, meta_id(ctx, meta))
		wr_name(ctx, &w, data[3])
		return exec_simple(ctx, &w)
	}
	return wj.UNDEFINED
}

// EX_PUT: [T, storeMeta, flags, keyBytes|null, valueBytes, kp|null, generate, snapshot|null]
@(private = "file")
exec_put :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, txid: u64, data: [^]wj.JSValue) -> wj.JSValue {
	meta := data[1]
	flags: i32
	wj.JS_ToInt32(ctx, &flags, data[2])
	kp := data[5]
	generate := wj.JS_ToBool(ctx, data[6]) != 0
	store := meta_id(ctx, meta)
	kb := wj.JS_DupValue(ctx, data[3])
	vb := wj.JS_DupValue(ctx, data[4])
	ik: wj.JSValue
	if generate {
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_PEEK_KEY, store)
		r: Rd
		keep: wj.JSValue
		if !exec_frame(ctx, &w, &r, &keep) { wj.JS_FreeValue(ctx, kb); wj.JS_FreeValue(ctx, vb); return wj.EXCEPTION }
		gen := rd_bytes(&r)
		copy_p := ([^]u8)(wj.js_malloc(ctx, uint(max(len(gen), 1))))
		if len(gen) > 0 { wj.memcpy(copy_p, raw_data(gen), uint(len(gen))) }
		wj.JS_FreeValue(ctx, kb)
		kb = wj.wj_uint8array_take(ctx, copy_p, uint(len(gen)))
		flags |= 2   // the key flag is read when the request runs: the generated key counts (idb.js: kb !== null)
		wj.JS_FreeValue(ctx, keep)
		clone := deserialize(ctx, data[4])
		decoded := key_value(ctx, kb)
		// inject the generated key as an own data property (CreateDataProperty, in web_idb_native.odin): never a
		// [[Set]], so a setter on the prototype (Object.prototype.id) is not run. A thrown inject must abort the
		// request, not leave a pending exception to surface later.
		ir := call3(ctx, M.h_inject, clone, kp, decoded)
		wj.JS_FreeValue(ctx, decoded)
		if wj.is_exception(ir) { wj.JS_FreeValue(ctx, clone); wj.JS_FreeValue(ctx, kb); wj.JS_FreeValue(ctx, vb); return wj.EXCEPTION }
		wj.JS_FreeValue(ctx, ir)
		wj.JS_FreeValue(ctx, vb)
		vb = serialize(ctx, clone)
		if wj.is_exception(vb) { wj.JS_FreeValue(ctx, clone); wj.JS_FreeValue(ctx, kb); return wj.EXCEPTION }
		snap := snap_index_keys(ctx, meta, clone)
		ik = index_key_list(ctx, meta, snap, vb)
		wj.JS_FreeValue(ctx, snap)
		wj.JS_FreeValue(ctx, clone)
	} else {
		ik = index_key_list(ctx, meta, data[7], vb)
	}
	a := [6]wj.JSValue{ num(ctx, txid), num(ctx, store), wj.new_int32(flags), wj.is_null(kb) ? wj.NULL : kb, vb, ik }
	r := h_exec(ctx, M.h_execPut, a[:])
	wj.JS_FreeValue(ctx, kb)
	wj.JS_FreeValue(ctx, vb)
	wj.JS_FreeValue(ctx, ik)
	return r
}

// ---- IDBRecord ----

make_record :: proc "contextless" (ctx: ^wj.Context, key, pk, value: wj.JSValue) -> wj.JSValue {
	r := obj_create(ctx, M.proto_IDBRecord)
	s := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, s, "key", wj.JS_DupValue(ctx, key))
	wj.JS_SetPropertyStr(ctx, s, "primaryKey", wj.JS_DupValue(ctx, pk))
	wj.JS_SetPropertyStr(ctx, s, "value", wj.JS_DupValue(ctx, value))
	wm_set(ctx, M.recordState, r, s)
	wj.JS_FreeValue(ctx, s)
	return r
}
record_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, magic: i32) -> wj.JSValue {
	s := state_of(ctx, M.recordState, this_val)
	if wj.is_exception(s) { return s }
	r := wj.JS_GetPropertyStr(ctx, s, magic == 0 ? "key" : magic == 1 ? "primaryKey" : "value")
	wj.JS_FreeValue(ctx, s)
	return r
}

// ---- IDBRequest getters ----

@(private = "file")
req_done_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	r := state_of(ctx, M.reqState, this_val)
	if wj.is_exception(r) { return r }
	defer wj.JS_FreeValue(ctx, r)
	if !pstr_eq(ctx, r, "readyState", "done") { return throw_dom(ctx, "InvalidStateError", "The request has not finished.") }
	return pget(ctx, r, field)
}
@(private = "file")
req_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: cstring) -> wj.JSValue {
	r := state_of(ctx, M.reqState, this_val)
	if wj.is_exception(r) { return r }
	v := pget(ctx, r, field)
	wj.JS_FreeValue(ctx, r)
	return v
}
req_get_result      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return req_done_field(ctx, this_val, "result") }
req_get_error       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return req_done_field(ctx, this_val, "error") }
req_get_source      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return req_field(ctx, this_val, "source") }
req_get_ready_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return req_field(ctx, this_val, "readyState") }
req_get_transaction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	tx := req_field(ctx, this_val, "tx")
	if wj.is_exception(tx) || wj.is_null(tx) { return tx }
	w := pget(ctx, tx, "wrapper")
	wj.JS_FreeValue(ctx, tx)
	return w
}

// ---- IDBTransaction bookkeeping: newTransaction, abortTransaction, forgetTx, restoreMeta, snapshotMeta ----

new_transaction :: proc "contextless" (ctx: ^wj.Context, conn: wj.JSValue, id: u64, mode: cstring, scope: wj.JSValue, durability: cstring) -> wj.JSValue {
	w := obj_create(ctx, M.proto_IDBTransaction)
	et_init(ctx, w)
	T := wj.JS_NewObject(ctx)
	set_own(ctx, T, "id", wj.new_int64(ctx, i64(id)))
	wj.JS_SetPropertyStr(ctx, T, "conn", wj.JS_DupValue(ctx, conn))
	wj.JS_SetPropertyStr(ctx, T, "mode", wj.new_string(ctx, mode))
	wj.JS_SetPropertyStr(ctx, T, "scope", wj.JS_DupValue(ctx, scope))
	wj.JS_SetPropertyStr(ctx, T, "durability", wj.new_string(ctx, durability))
	wj.JS_SetPropertyStr(ctx, T, "state", wj.new_string(ctx, "active"))
	wj.JS_SetPropertyStr(ctx, T, "started", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, T, "queue", wj.JS_NewArray(ctx))
	wj.JS_SetPropertyStr(ctx, T, "busy", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, T, "error", wj.NULL)
	wj.JS_SetPropertyStr(ctx, T, "wrapper", wj.JS_DupValue(ctx, w))
	wj.JS_SetPropertyStr(ctx, T, "stores", map_new(ctx))
	wj.JS_SetPropertyStr(ctx, T, "names", wj.NULL)
	wj.JS_SetPropertyStr(ctx, T, "commitSent", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, T, "dead", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, T, "upgradeReq", wj.NULL)
	wj.JS_SetPropertyStr(ctx, T, "backup", wj.NULL)
	wj.JS_SetPropertyStr(ctx, T, "startedEarly", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, T, "oldVersion", wj.new_int32(0))
	wm_set(ctx, M.txState, w, T)
	idv := wj.new_int64(ctx, i64(id))
	map_set(ctx, M.txs, idv, T)
	wj.JS_FreeValue(ctx, idv)
	pset(ctx, conn, "txCount", wj.new_int64(ctx, pint(ctx, conn, "txCount") + 1))
	activate(ctx, T)
	wj.JS_FreeValue(ctx, w)
	return T
}

// snapshotMeta(c): [{ meta, name, indexes: slice, names: indexes.map(name) }]
snapshot_meta :: proc "contextless" (ctx: ^wj.Context, c: wj.JSValue) -> wj.JSValue {
	out := wj.JS_NewArray(ctx)
	stores := pget(ctx, c, "stores")
	n: i64
	wj.JS_GetLength(ctx, stores, &n)
	for i in 0 ..< n {
		s := wj.JS_GetPropertyInt64(ctx, stores, i)
		rec := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, rec, "meta", wj.JS_DupValue(ctx, s))
		wj.JS_SetPropertyStr(ctx, rec, "name", wj.JS_GetPropertyStr(ctx, s, "name"))
		idx := wj.JS_GetPropertyStr(ctx, s, "indexes")
		indexes := method_call(ctx, idx, "slice", nil)
		wj.JS_SetPropertyStr(ctx, rec, "indexes", wj.JS_DupValue(ctx, indexes))
		names := wj.JS_NewArray(ctx)
		m: i64
		wj.JS_GetLength(ctx, indexes, &m)
		for j in 0 ..< m {
			ix := wj.JS_GetPropertyInt64(ctx, indexes, j)
			wj.JS_SetPropertyInt64(ctx, names, j, wj.JS_GetPropertyStr(ctx, ix, "name"))
			wj.JS_FreeValue(ctx, ix)
		}
		wj.JS_SetPropertyStr(ctx, rec, "names", names)
		wj.JS_FreeValue(ctx, indexes)
		wj.JS_FreeValue(ctx, idx)
		wj.JS_FreeValue(ctx, s)
		wj.JS_SetPropertyInt64(ctx, out, i, rec)
	}
	wj.JS_FreeValue(ctx, stores)
	return out
}

// Marks every element of an array of metadata deleted (or not).
@(private = "file")
mark_deleted :: proc "contextless" (ctx: ^wj.Context, list: wj.JSValue, deleted: bool) {
	n: i64
	wj.JS_GetLength(ctx, list, &n)
	for i in 0 ..< n {
		x := wj.JS_GetPropertyInt64(ctx, list, i)
		pset(ctx, x, "deleted", wj.new_bool(deleted))
		wj.JS_FreeValue(ctx, x)
	}
}

// restoreMeta(T): put the connection's metadata back after an aborted version change
restore_meta :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) {
	c := pget(ctx, T, "conn")
	b := pget(ctx, T, "backup")
	defer { wj.JS_FreeValue(ctx, b); wj.JS_FreeValue(ctx, c) }
	if wj.is_null(b) { return }
	// keep = new Set(b.map(x => x.meta))
	keep := set_new(ctx)
	bn: i64
	wj.JS_GetLength(ctx, b, &bn)
	for i in 0 ..< bn {
		x := wj.JS_GetPropertyInt64(ctx, b, i)
		m := wj.JS_GetPropertyStr(ctx, x, "meta")
		set_add(ctx, keep, m)
		wj.JS_FreeValue(ctx, m)
		wj.JS_FreeValue(ctx, x)
	}
	stores := pget(ctx, c, "stores")
	sn: i64
	wj.JS_GetLength(ctx, stores, &sn)
	has_f := wj.JS_GetPropertyStr(ctx, keep, "has")
	for i in 0 ..< sn {
		s := wj.JS_GetPropertyInt64(ctx, stores, i)
		hr := wj.JS_Call(ctx, has_f, keep, 1, &s)
		kept := wj.JS_ToBool(ctx, hr) != 0
		wj.JS_FreeValue(ctx, hr)
		if !kept {
			pset(ctx, s, "deleted", wj.TRUE)
			idx := wj.JS_GetPropertyStr(ctx, s, "indexes")
			mark_deleted(ctx, idx, true)
			wj.JS_FreeValue(ctx, idx)
		}
		wj.JS_FreeValue(ctx, s)
	}
	wj.JS_FreeValue(ctx, has_f)
	wj.JS_FreeValue(ctx, stores)
	wj.JS_FreeValue(ctx, keep)
	// c.stores = b.map(x => x.meta)
	new_stores := wj.JS_NewArray(ctx)
	for i in 0 ..< bn {
		x := wj.JS_GetPropertyInt64(ctx, b, i)
		meta := wj.JS_GetPropertyStr(ctx, x, "meta")
		wj.JS_SetPropertyInt64(ctx, new_stores, i, wj.JS_DupValue(ctx, meta))
		// restore the store's name, deleted flag, indexes
		pset(ctx, meta, "name", wj.JS_GetPropertyStr(ctx, x, "name"))
		pset(ctx, meta, "deleted", wj.FALSE)
		x_indexes := wj.JS_GetPropertyStr(ctx, x, "indexes")
		meta_indexes := wj.JS_GetPropertyStr(ctx, meta, "indexes")
		mi: i64
		wj.JS_GetLength(ctx, meta_indexes, &mi)
		// indexes created since but not in x.indexes: mark deleted
		incl_f := wj.JS_GetPropertyStr(ctx, x_indexes, "includes")
		for j in 0 ..< mi {
			ix := wj.JS_GetPropertyInt64(ctx, meta_indexes, j)
			ir := wj.JS_Call(ctx, incl_f, x_indexes, 1, &ix)
			if wj.JS_ToBool(ctx, ir) == 0 { pset(ctx, ix, "deleted", wj.TRUE) }
			wj.JS_FreeValue(ctx, ir)
			wj.JS_FreeValue(ctx, ix)
		}
		wj.JS_FreeValue(ctx, incl_f)
		wj.JS_FreeValue(ctx, meta_indexes)
		// meta.indexes = x.indexes.slice()
		indexes_copy := method_call(ctx, x_indexes, "slice", nil)
		pset(ctx, meta, "indexes", wj.JS_DupValue(ctx, indexes_copy))
		// meta.hostIndexes = x.indexes.filter(ix => ix.ready)
		host_indexes := wj.JS_NewArray(ctx)
		xn: i64
		wj.JS_GetLength(ctx, indexes_copy, &xn)
		hk: u32
		for j in 0 ..< xn {
			ix := wj.JS_GetPropertyInt64(ctx, indexes_copy, j)
			if pbool(ctx, ix, "ready") { wj.JS_SetPropertyUint32(ctx, host_indexes, hk, wj.JS_DupValue(ctx, ix)); hk += 1 }
			wj.JS_FreeValue(ctx, ix)
		}
		pset(ctx, meta, "hostIndexes", host_indexes)
		// meta.indexes.forEach((ix, i) => { ix.name = x.names[i]; ix.deleted = false; })
		x_names := wj.JS_GetPropertyStr(ctx, x, "names")
		for j in 0 ..< xn {
			ix := wj.JS_GetPropertyInt64(ctx, indexes_copy, j)
			pset(ctx, ix, "name", wj.JS_GetPropertyInt64(ctx, x_names, j))
			pset(ctx, ix, "deleted", wj.FALSE)
			wj.JS_FreeValue(ctx, ix)
		}
		wj.JS_FreeValue(ctx, x_names)
		wj.JS_FreeValue(ctx, indexes_copy)
		wj.JS_FreeValue(ctx, x_indexes)
		wj.JS_FreeValue(ctx, meta)
		wj.JS_FreeValue(ctx, x)
	}
	pset(ctx, c, "stores", new_stores)
	update_names(ctx, c)
}

// connection.upgradeTx = null when it is T
@(private = "file")
clear_upgrade_tx :: proc "contextless" (ctx: ^wj.Context, conn: wj.JSValue, T: wj.JSValue) {
	up := pget(ctx, conn, "upgradeTx")
	if wj.same_ptr(up, T) { pset(ctx, conn, "upgradeTx", wj.NULL) }
	wj.JS_FreeValue(ctx, up)
}

forget_tx :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) {
	idv := wj.new_int64(ctx, pint(ctx, T, "id"))
	map_delete(ctx, M.txs, idv)
	wj.JS_FreeValue(ctx, idv)
	conn := pget(ctx, T, "conn")
	clear_upgrade_tx(ctx, conn, T)
	wj.JS_FreeValue(ctx, conn)
}

// a posted "abort a pending request" (fails R with AbortError and fires error)
task_run_abort_req :: proc "contextless" (ctx: ^wj.Context, R: wj.JSValue) {
	pstr(ctx, R, "readyState", "done")
	pset(ctx, R, "result", wj.UNDEFINED)
	pset(ctx, R, "error", dom_ex(ctx, "AbortError", "The transaction was aborted."))
	w := pget(ctx, R, "wrapper")
	dispatch(ctx, w, plain_event(ctx, "error", true, true))
	wj.JS_FreeValue(ctx, w)
}
// a posted "finish an aborted transaction": fire abort at it and forget it
task_run_abort_finish :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue) {
	conn := pget(ctx, T, "conn")
	clear_upgrade_tx(ctx, conn, T)
	w := pget(ctx, T, "wrapper")
	dispatch(ctx, w, plain_event(ctx, "abort", true, false))
	wj.JS_FreeValue(ctx, w)
	up_req := pget(ctx, T, "upgradeReq")
	if !wj.is_null(up_req) { pset(ctx, up_req, "tx", wj.NULL) }
	wj.JS_FreeValue(ctx, up_req)
	pset(ctx, conn, "txCount", wj.new_int64(ctx, pint(ctx, conn, "txCount") - 1))
	forget_tx(ctx, T)
	wj.JS_FreeValue(ctx, conn)
}

// abortTransaction(T, error, code, tellHost)
abort_transaction :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, error: wj.JSValue, code: i32, tell_host: bool) {
	if pbool(ctx, T, "dead") { return }
	pset(ctx, T, "dead", wj.TRUE)
	pstr(ctx, T, "state", "finished")
	pset(ctx, T, "error", wj.JS_DupValue(ctx, error))
	set_delete(ctx, M.activeSet, T)
	// pending = T.queue.splice(0)
	queue := pget(ctx, T, "queue")
	zero := wj.new_int32(0)
	pending := method_call(ctx, queue, "splice", ([^]wj.JSValue)(&zero)[:1])
	wj.JS_FreeValue(ctx, queue)
	if pstr_eq(ctx, T, "mode", "versionchange") {
		restore_meta(ctx, T)
		conn := pget(ctx, T, "conn")
		pset(ctx, conn, "version", wj.new_int64(ctx, pint(ctx, T, "oldVersion")))
		wj.JS_FreeValue(ctx, conn)
	}
	pn: i64
	wj.JS_GetLength(ctx, pending, &pn)
	for i in 0 ..< pn {
		q := wj.JS_GetPropertyInt64(ctx, pending, i)
		R := wj.JS_GetPropertyStr(ctx, q, "R")
		if !wj.is_null(R) { post_closure(ctx, TASK_ABORT_REQ, R) }
		wj.JS_FreeValue(ctx, R)
		wj.JS_FreeValue(ctx, q)
	}
	wj.JS_FreeValue(ctx, pending)
	post_closure(ctx, TASK_ABORT_FINISH, T)
	if tell_host {
		w := Wr{ ctx = ctx }
		wr_uv(&w, u64(pint(ctx, T, "id")))
		wr_u8(&w, u8(code))
		wj.JS_FreeValue(ctx, host_call1(ctx, OP_ABORT, wr_u8array(ctx, &w)))
		wr_free(&w)
	}
	idv := wj.new_int64(ctx, pint(ctx, T, "id"))
	map_delete(ctx, M.txs, idv)
	wj.JS_FreeValue(ctx, idv)
}

// ---- object stores and indexes: state, checks, request builders ----

// storeFor(T, meta): the IDBObjectStore for meta in transaction T (cached in T.stores)
store_for :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, meta: wj.JSValue) -> wj.JSValue {
	stores := pget(ctx, T, "stores")
	w := map_get(ctx, stores, meta)
	if wj.is_undefined(w) {
		w = obj_create(ctx, M.proto_IDBObjectStore)
		s := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, s, "meta", wj.JS_DupValue(ctx, meta))
		wj.JS_SetPropertyStr(ctx, s, "tx", wj.JS_DupValue(ctx, T))
		wj.JS_SetPropertyStr(ctx, s, "indexes", map_new(ctx))
		wj.JS_SetPropertyStr(ctx, s, "wrapper", wj.JS_DupValue(ctx, w))
		wj.JS_SetPropertyStr(ctx, s, "names", wj.NULL)
		wm_set(ctx, M.storeState, w, s)
		wj.JS_FreeValue(ctx, s)
		map_set(ctx, stores, meta, w)
	}
	wj.JS_FreeValue(ctx, stores)
	return w
}

// The transaction state of a store or an index when it is active (counted), else the TransactionInactiveError.
@(private = "file")
active_tx :: proc "contextless" (ctx: ^wj.Context, tx: wj.JSValue, T: ^wj.JSValue) -> bool {
	if !pstr_eq(ctx, tx, "state", "active") {
		fin := pstr_eq(ctx, tx, "state", "finished")
		wj.JS_FreeValue(ctx, tx)
		throw_dom(ctx, "TransactionInactiveError", fin ? "The transaction is finished." : "The transaction is not active.")
		return false
	}
	T^ = tx
	return true
}

// checkStore(S, write): S the store state; the transaction state in T (counted), or throws.
check_store :: proc "contextless" (ctx: ^wj.Context, S: wj.JSValue, write: bool, T: ^wj.JSValue) -> bool {
	meta := pget(ctx, S, "meta")
	deleted := pbool(ctx, meta, "deleted")
	wj.JS_FreeValue(ctx, meta)
	if deleted { throw_dom(ctx, "InvalidStateError", "The object store has been deleted."); return false }
	tx := pget(ctx, S, "tx")
	if !active_tx(ctx, tx, T) { return false }
	if write && pstr_eq(ctx, T^, "mode", "readonly") {
		wj.JS_FreeValue(ctx, T^)
		throw_dom(ctx, "ReadOnlyError", "The transaction is read-only.")
		return false
	}
	return true
}

// cloneValue(T, value): serialize with the transaction inactive
clone_value :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, value: wj.JSValue) -> wj.JSValue {
	prev := pget(ctx, T, "state")
	pstr(ctx, T, "state", "inactive")
	r := serialize(ctx, value)
	if pstr_eq(ctx, T, "state", "inactive") { pset(ctx, T, "state", wj.JS_DupValue(ctx, prev)) }
	wj.JS_FreeValue(ctx, prev)
	return r
}

// A request of the store S (or of index `index`) in T from `src`, its exec made from data[1:] after T; returns the
// request's wrapper. Takes nothing.
@(private = "file")
enqueue_request :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, src: wj.JSValue, kind: i32, data: []wj.JSValue) -> wj.JSValue {
	reqs := new_request(ctx, M.proto_IDBRequest, src, T)
	Rw := pget(ctx, reqs, "wrapper")
	et_init(ctx, Rw)
	enqueue(ctx, T, reqs, make_exec(ctx, kind, data))
	wj.JS_FreeValue(ctx, reqs)
	return Rw
}

// getRequest(S, index_meta|null, T, srcWrapper, keyOnly, query): a get / getKey request
get_request :: proc "contextless" (ctx: ^wj.Context, S, index, T, src: wj.JSValue, key_only: bool, query: wj.JSValue, optional: bool) -> wj.JSValue {
	range := range_arg(ctx, query, optional)
	if wj.is_exception(range) { return range }
	meta := pget(ctx, S, "meta")
	rbytes := pack_range(ctx, range)
	d := [5]wj.JSValue{ T, meta, index, rbytes, wj.new_bool(key_only) }
	Rw := enqueue_request(ctx, T, src, EX_GET, d[:])
	wj.JS_FreeValue(ctx, rbytes)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, range)
	return Rw
}
count_request :: proc "contextless" (ctx: ^wj.Context, S, index, T, src: wj.JSValue, query: wj.JSValue) -> wj.JSValue {
	range := range_arg(ctx, query, true)
	if wj.is_exception(range) { return range }
	meta := pget(ctx, S, "meta")
	rbytes := pack_range(ctx, range)
	d := [4]wj.JSValue{ T, meta, index, rbytes }
	Rw := enqueue_request(ctx, T, src, EX_COUNT, d[:])
	wj.JS_FreeValue(ctx, rbytes)
	wj.JS_FreeValue(ctx, meta)
	wj.JS_FreeValue(ctx, range)
	return Rw
}

// a plain object (its prototype is Object.prototype or null)
is_dictionary :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> bool {
	if wj.is_null(v) || !wj.is_object(v) { return false }
	p := wj.JS_GetPrototype(ctx, v)
	objc := g_prop(ctx, "Object")
	op := wj.JS_GetPropertyStr(ctx, objc, "prototype")
	wj.JS_FreeValue(ctx, objc)
	plain := wj.is_null(p) || wj.same_ptr(p, op)
	wj.JS_FreeValue(ctx, p)
	wj.JS_FreeValue(ctx, op)
	return plain
}

// IDBCursorDirection
DIRS := [4]string{ "next", "nextunique", "prev", "prevunique" }

// The list arguments of getAll / getAllKeys / getAllRecords: the range state (or null), the limit, the direction.
List_Args :: struct {
	range:     wj.JSValue,   // counted
	limit:     u32,
	backwards: bool,
	unique:    bool,
}

@(private = "file")
direction_flags :: proc "contextless" (dir: int, a: ^List_Args) {
	a.backwards = dir == 2 || dir == 3
	a.unique = dir == 1 || dir == 3
}

// listArgs(queryOrOptions, count): false with an exception pending
list_args :: proc "contextless" (ctx: ^wj.Context, query_or_options: wj.JSValue, count: wj.JSValue, out: ^List_Args) -> bool {
	query := wj.JS_DupValue(ctx, query_or_options)
	count_v := wj.JS_DupValue(ctx, count)
	defer { wj.JS_FreeValue(ctx, query); wj.JS_FreeValue(ctx, count_v) }
	dir := 0
	if is_dictionary(ctx, query_or_options) && !wm_has(ctx, M.rangeState, query_or_options) {
		k := key_of(ctx, query_or_options)
		if wj.is_exception(k) { return false }
		is_key := !wj.is_null(k)
		wj.JS_FreeValue(ctx, k)
		if !is_key {
			wj.JS_FreeValue(ctx, query)
			query = wj.JS_GetPropertyStr(ctx, query_or_options, "query")
			cnt := wj.JS_GetPropertyStr(ctx, query_or_options, "count")
			if !wj.is_undefined(cnt) { wj.JS_FreeValue(ctx, count_v); count_v = cnt }
			d := wj.JS_GetPropertyStr(ctx, query_or_options, "direction")
			if !wj.is_undefined(d) {
				i, ok := check_enum(ctx, d, DIRS[:], "IDBCursorDirection")
				if !ok { wj.JS_FreeValue(ctx, d); return false }
				dir = i
			}
			wj.JS_FreeValue(ctx, d)
		}
	}
	out.range = range_arg(ctx, query, true)
	if wj.is_exception(out.range) { return false }
	out.limit = 0
	if !wj.is_undefined(count_v) && !enforce_u_long(ctx, count_v, "count", &out.limit) { wj.JS_FreeValue(ctx, out.range); return false }
	direction_flags(dir, out)
	return true
}

// optionsArgs(options) of getAllRecords: false with an exception pending
options_args :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, out: ^List_Args) -> bool {
	dir := 0
	query, count := wj.UNDEFINED, wj.UNDEFINED
	defer { wj.JS_FreeValue(ctx, query); wj.JS_FreeValue(ctx, count) }
	if !wj.is_nullish(opt) {
		if !wj.is_object(opt) { type_error(ctx, "The options argument is not of type 'IDBGetAllOptions'."); return false }
		d := wj.JS_GetPropertyStr(ctx, opt, "direction")
		if !wj.is_undefined(d) {
			i, ok := check_enum(ctx, d, DIRS[:], "IDBCursorDirection")
			if !ok { wj.JS_FreeValue(ctx, d); return false }
			dir = i
		}
		wj.JS_FreeValue(ctx, d)
		query = wj.JS_GetPropertyStr(ctx, opt, "query")
		count = wj.JS_GetPropertyStr(ctx, opt, "count")
	}
	out.range = range_arg(ctx, query, true)
	if wj.is_exception(out.range) { return false }
	out.limit = 0
	if !wj.is_undefined(count) && !enforce_u_long(ctx, count, "count", &out.limit) { wj.JS_FreeValue(ctx, out.range); return false }
	direction_flags(dir, out)
	return true
}

// getAllRequest(S, index_meta|null, T, srcWrapper, mode, args)
get_all_request :: proc "contextless" (ctx: ^wj.Context, S, index, T, src: wj.JSValue, mode: i32, a: ^List_Args) -> wj.JSValue {
	meta := pget(ctx, S, "meta")
	rbytes := pack_range(ctx, a.range)
	flags := (a.backwards ? 1 : 0) | (a.unique ? 2 : 0)
	d := [7]wj.JSValue{ T, meta, index, rbytes, wj.new_int32(mode), wj.new_int32(i32(flags)), wj.new_int64(ctx, i64(a.limit)) }
	Rw := enqueue_request(ctx, T, src, EX_GET_ALL, d[:])
	wj.JS_FreeValue(ctx, rbytes)
	wj.JS_FreeValue(ctx, meta)
	return Rw
}

// doPut(S, value, key, noOverwrite): the put / add request
do_put :: proc "contextless" (ctx: ^wj.Context, S: wj.JSValue, value: wj.JSValue, key: wj.JSValue, no_overwrite: bool) -> wj.JSValue {
	T: wj.JSValue
	if !check_store(ctx, S, true, &T) { return wj.EXCEPTION }
	meta := pget(ctx, S, "meta")
	kp := pget(ctx, meta, "keyPath")
	key_bytes := wj.NULL
	bytes := wj.UNDEFINED
	eval_value := wj.UNDEFINED
	defer {
		wj.JS_FreeValue(ctx, eval_value)
		wj.JS_FreeValue(ctx, bytes)
		wj.JS_FreeValue(ctx, key_bytes)
		wj.JS_FreeValue(ctx, kp)
		wj.JS_FreeValue(ctx, meta)
		wj.JS_FreeValue(ctx, T)
	}
	auto_increment := pbool(ctx, meta, "autoIncrement")
	has_key := !wj.is_undefined(key)
	if !wj.is_null(kp) && has_key { return throw_dom(ctx, "DataError", "The object store uses in-line keys and the key parameter was provided.") }
	if wj.is_null(kp) && !auto_increment && !has_key {
		return throw_dom(ctx, "DataError", "The object store uses out-of-line keys and has no key generator and the key parameter was not provided.")
	}
	if has_key {
		key_bytes = key_of(ctx, key)
		if wj.is_exception(key_bytes) { key_bytes = wj.NULL; return wj.EXCEPTION }
		if wj.is_null(key_bytes) { return throw_dom(ctx, "DataError", "The parameter is not a valid key.") }
	}
	bytes = clone_value(ctx, T, value)
	if wj.is_exception(bytes) { bytes = wj.UNDEFINED; return wj.EXCEPTION }
	generate := false
	indexes := pget(ctx, meta, "indexes")
	ni: i64
	wj.JS_GetLength(ctx, indexes, &ni)
	wj.JS_FreeValue(ctx, indexes)
	need_eval := wj.is_object(value) && (!wj.is_null(kp) || ni > 0)
	eval_value = need_eval ? deserialize(ctx, bytes) : wj.JS_DupValue(ctx, value)
	if !wj.is_null(kp) {
		k := call2(ctx, M.h_pathKey, eval_value, kp)
		if wj.is_exception(k) { return k }
		if wj.is_null(k) { return throw_dom(ctx, "DataError", "The key path yielded a value that is not a valid key.") }
		if wj.is_undefined(k) {
			if !auto_increment { return throw_dom(ctx, "DataError", "Evaluating the object store's key path did not yield a value.") }
			can := false
			if wj.is_string(kp) {
				cr := call2(ctx, M.h_canInject, eval_value, kp)
				can = wj.JS_ToBool(ctx, cr) != 0
				wj.JS_FreeValue(ctx, cr)
			}
			if !wj.is_string(kp) || !can { return throw_dom(ctx, "DataError", "A key could not be injected into the value.") }
			generate = true
		} else {
			wj.JS_FreeValue(ctx, key_bytes)
			key_bytes = k
		}
	}
	src := pget(ctx, S, "wrapper")
	reqs := new_request(ctx, M.proto_IDBRequest, src, T)
	wj.JS_FreeValue(ctx, src)
	Rw := pget(ctx, reqs, "wrapper")
	et_init(ctx, Rw)
	snapshot := generate ? wj.NULL : snap_index_keys(ctx, meta, eval_value)
	flags := (no_overwrite ? 1 : 0) | (!wj.is_null(key_bytes) ? 2 : 0) | (generate ? 4 : 0)
	d := [8]wj.JSValue{ T, meta, wj.new_int32(i32(flags)), key_bytes, bytes, kp, wj.new_bool(generate), snapshot }
	enqueue(ctx, T, reqs, make_exec(ctx, EX_PUT, d[:]))
	wj.JS_FreeValue(ctx, snapshot)
	wj.JS_FreeValue(ctx, reqs)
	return Rw
}

// populateIndex(T, S_meta, ix): fill a new index from the store's records (a Failure thrown on an error)
populate_index :: proc "contextless" (ctx: ^wj.Context, T: wj.JSValue, s_meta: wj.JSValue, ix: wj.JSValue) {
	store := u64(pint(ctx, s_meta, "id"))
	after := wj.NULL
	kp := pget(ctx, ix, "keyPath")
	defer { wj.JS_FreeValue(ctx, after); wj.JS_FreeValue(ctx, kp) }
	multi := pbool(ctx, ix, "multiEntry")
	ixid := u64(pint(ctx, ix, "id"))
	for {
		w := Wr{ ctx = ctx }
		req_writer(ctx, &w, T, REQ_GET_ALL, store)
		wr_uv(&w, 0)
		if wj.is_null(after) {
			wr_u8(&w, 0)
		} else {
			ap, _ := reply_bytes(ctx, after)
			wr_u8(&w, 1 | 4)   // lower present, lowerOpen
			wr_bytes(&w, ap)
		}
		wr_u8(&w, 3)
		wr_u8(&w, 0)
		wr_uv(&w, 256)
		r: Rd
		keep: wj.JSValue
		if !exec_frame(ctx, &w, &r, &keep) { return }
		n := rd_uv(&r)
		if n == 0 { wj.JS_FreeValue(ctx, keep); break }
		failed := false
		for i: u64 = 0; i < n && !r.bad; i += 1 {
			rd_bytes(&r)   // the index key of a record of the store (unused)
			pk := rd_bytes(&r)
			vb := rd_bytes(&r)
			if r.bad { break }
			// after = pk (a copy that survives the next EXEC)
			pcopy := ([^]u8)(wj.js_malloc(ctx, uint(max(len(pk), 1))))
			if len(pk) > 0 { wj.memcpy(pcopy, raw_data(pk), uint(len(pk))) }
			wj.JS_FreeValue(ctx, after)
			after = wj.wj_uint8array_take(ctx, pcopy, uint(len(pk)))
			value := clone_deserialize(ctx, raw_data(vb), uint(len(vb)))
			keys := index_keys(ctx, value, kp, multi)
			wj.JS_FreeValue(ctx, value)
			kc: i64
			wj.JS_GetLength(ctx, keys, &kc)
			if kc == 0 { wj.JS_FreeValue(ctx, keys); continue }
			iw := Wr{ ctx = ctx }
			req_writer(ctx, &iw, T, REQ_INDEX_PUT, store)
			wr_uv(&iw, ixid)
			wr_bytes(&iw, pk)
			wr_uv(&iw, u64(kc))
			for j in 0 ..< kc {
				kv := wj.JS_GetPropertyInt64(ctx, keys, j)
				kb, _ := reply_bytes(ctx, kv)
				wr_bytes(&iw, kb)
				wj.JS_FreeValue(ctx, kv)
			}
			wj.JS_FreeValue(ctx, keys)
			if iw.oom { wr_free(&iw); wj.JS_ThrowOutOfMemory(ctx); failed = true; break }
			rep2 := host_call1(ctx, OP_EXEC, wr_u8array(ctx, &iw))
			wr_free(&iw)
			st := reply_status(ctx, rep2)
			wj.JS_FreeValue(ctx, rep2)
			if st != 0 { wj.JS_Throw(ctx, new_failure(ctx, st, "Unable to add the index entries.")); failed = true; break }
		}
		more := rd_u8(&r)
		wj.JS_FreeValue(ctx, keep)
		if failed { return }
		if n < 256 && more == 0 { break }
	}
}

// indexFor(S, meta): the IDBIndex for meta (cached in S.indexes)
index_for :: proc "contextless" (ctx: ^wj.Context, S: wj.JSValue, meta: wj.JSValue) -> wj.JSValue {
	indexes := pget(ctx, S, "indexes")
	w := map_get(ctx, indexes, meta)
	if wj.is_undefined(w) {
		w = obj_create(ctx, M.proto_IDBIndex)
		s := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, s, "meta", wj.JS_DupValue(ctx, meta))
		wj.JS_SetPropertyStr(ctx, s, "store", wj.JS_DupValue(ctx, S))
		wj.JS_SetPropertyStr(ctx, s, "wrapper", wj.JS_DupValue(ctx, w))
		wm_set(ctx, M.indexState, w, s)
		wj.JS_FreeValue(ctx, s)
		map_set(ctx, indexes, meta, w)
	}
	wj.JS_FreeValue(ctx, indexes)
	return w
}

// checkIndex(X): X the index state; the transaction state in T (counted), or throws.
check_index :: proc "contextless" (ctx: ^wj.Context, X: wj.JSValue, T: ^wj.JSValue) -> bool {
	meta := pget(ctx, X, "meta")
	store := pget(ctx, X, "store")
	smeta := pget(ctx, store, "meta")
	del := pbool(ctx, meta, "deleted") || pbool(ctx, smeta, "deleted")
	wj.JS_FreeValue(ctx, smeta)
	wj.JS_FreeValue(ctx, meta)
	if del { wj.JS_FreeValue(ctx, store); throw_dom(ctx, "InvalidStateError", "The index or its object store has been deleted."); return false }
	tx := pget(ctx, store, "tx")
	wj.JS_FreeValue(ctx, store)
	return active_tx(ctx, tx, T)
}
