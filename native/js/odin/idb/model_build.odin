// model_build.odin: building the classes and the exports. Each interface is a constructor function (throwing "Illegal
// constructor" unless it has its own) with a prototype carrying the members. exposeMembers makes the members enumerable
// and sets Symbol.toStringTag; start() links the event-target prototypes to the realm's EventTarget and the event
// prototypes to Event (the realm's interfaces exist by the time the model is built on first use). Ported from
// web_idb_prelude.c (same names).
package idb

import "../wj"

// A bare interface class: a constructor `ctor_fn` (default illegal) and its prototype. Sets ctor.prototype and
// proto.constructor; name and length as a built-in.
@(private = "file")
make_interface :: proc "contextless" (ctx: ^wj.Context, name: cstring, ctor_fn: wj.Native, length: i32, cls, proto: ^wj.JSValue) {
	p := wj.JS_NewObject(ctx)
	c := wj.JS_NewCFunction2(ctx, ctor_fn != nil ? ctor_fn : illegal_ctor, name, length, wj.CFUNC_constructor, 0)
	wj.JS_SetConstructor(ctx, c, p)
	wj.JS_DefinePropertyValueStr(ctx, c, "prototype", wj.JS_DupValue(ctx, p), 0)
	cls^ = c
	proto^ = p
}

// Symbol[name] as an atom (free it)
@(private = "file")
symbol_atom :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.Atom {
	sym := g_prop(ctx, "Symbol")
	s := wj.JS_GetPropertyStr(ctx, sym, name)
	a := wj.JS_ValueToAtom(ctx, s)
	wj.JS_FreeValue(ctx, s)
	wj.JS_FreeValue(ctx, sym)
	return a
}

// set Symbol.toStringTag on a prototype
@(private = "file")
set_tag :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue, tag: cstring) {
	a := symbol_atom(ctx, "toStringTag")
	wj.JS_DefinePropertyValue(ctx, proto, a, wj.new_string(ctx, tag), wj.PROP_CONFIGURABLE)
	wj.JS_FreeAtom(ctx, a)
}

// exposeMembers(cls): the operations and attributes on the prototype and statics on the constructor become
// enumerable; Symbol.toStringTag = cls.name on the prototype. (Like the old exposeMembers.)
@(private = "file")
expose_members :: proc "contextless" (ctx: ^wj.Context, cls, proto: wj.JSValue, tag: cstring) {
	holders := [2]wj.JSValue{ proto, cls }
	objc := g_prop(ctx, "Object")
	reflect := g_prop(ctx, "Reflect")
	gopd := wj.JS_GetPropertyStr(ctx, objc, "getOwnPropertyDescriptor")
	defp := wj.JS_GetPropertyStr(ctx, objc, "defineProperty")
	ownk := wj.JS_GetPropertyStr(ctx, reflect, "ownKeys")
	for &holder, h in holders {
		keys := wj.JS_Call(ctx, ownk, reflect, 1, &holder)
		n: i64
		wj.JS_GetLength(ctx, keys, &n)
		for i in 0 ..< n {
			key := wj.JS_GetPropertyInt64(ctx, keys, i)
			defer wj.JS_FreeValue(ctx, key)
			if !wj.is_string(key) { continue }
			ks := wj.to_cstring(ctx, key)
			if ks == nil { continue }
			k := string(ks)
			skip := k == "constructor" || k == "prototype" || (h == 1 && (k == "length" || k == "name"))
			wj.free_cstring(ctx, ks)
			if skip { continue }
			ga := [2]wj.JSValue{ holder, key }
			d := wj.JS_Call(ctx, gopd, objc, 2, &ga[0])
			cfg := wj.JS_GetPropertyStr(ctx, d, "configurable")
			if wj.JS_ToBool(ctx, cfg) != 0 {
				wj.JS_SetPropertyStr(ctx, d, "enumerable", wj.TRUE)
				da := [3]wj.JSValue{ holder, key, d }
				wj.JS_FreeValue(ctx, wj.JS_Call(ctx, defp, objc, 3, &da[0]))
			}
			wj.JS_FreeValue(ctx, cfg)
			wj.JS_FreeValue(ctx, d)
		}
		wj.JS_FreeValue(ctx, keys)
	}
	wj.JS_FreeValue(ctx, ownk)
	wj.JS_FreeValue(ctx, reflect)
	wj.JS_FreeValue(ctx, gopd)
	wj.JS_FreeValue(ctx, defp)
	wj.JS_FreeValue(ctx, objc)
	set_tag(ctx, proto, tag)
}

// start(): link our event targets to EventTarget, our events to Event, DOMStringList to the realm's (web_idb.odin
// calls it)
@(private = "file")
idb_start :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	// DOMStringList.prototype inherits from the realm's DOMStringList.prototype (instanceof)
	realm_dsl := g_prop(ctx, "DOMStringList")
	if wj.JS_IsFunction(ctx, realm_dsl) {
		p := wj.JS_GetPropertyStr(ctx, realm_dsl, "prototype")
		wj.JS_SetPrototype(ctx, M.proto_DOMStringList, p)
		wj.JS_FreeValue(ctx, p)
	}
	wj.JS_FreeValue(ctx, realm_dsl)
	M.native_event = g_prop(ctx, "Event")
	M.global_event = wj.JS_DupValue(ctx, M.native_event)
	M.dom_exception = g_prop(ctx, "DOMException")
	M.global_event_target = g_prop(ctx, "EventTarget")
	// the roots of our event targets inherit from EventTarget, with their own add/remove/dispatch (copied from
	// IDBEventTarget.prototype)
	roots := [3]wj.JSValue{ M.cls_IDBRequest, M.cls_IDBDatabase, M.cls_IDBTransaction }
	root_protos := [3]wj.JSValue{ M.proto_IDBRequest, M.proto_IDBDatabase, M.proto_IDBTransaction }
	etp := wj.JS_GetPropertyStr(ctx, M.global_event_target, "prototype")
	for i in 0 ..< 3 {
		for name in ([3]cstring{ "addEventListener", "removeEventListener", "dispatchEvent" }) {
			d := wj.JS_GetPropertyStr(ctx, M.proto_IDBEventTarget, name)
			wj.JS_DefinePropertyValueStr(ctx, root_protos[i], name, d, wj.PROP_C_W_E)
		}
		wj.JS_SetPrototype(ctx, root_protos[i], etp)
		wj.JS_SetPrototype(ctx, roots[i], M.global_event_target)
	}
	wj.JS_FreeValue(ctx, etp)
	// IDBVersionChangeEvent and IDBPlainEvent inherit from Event
	evp := wj.JS_GetPropertyStr(ctx, M.native_event, "prototype")
	wj.JS_SetPrototype(ctx, M.proto_IDBVersionChangeEvent, evp)
	wj.JS_SetPrototype(ctx, M.cls_IDBVersionChangeEvent, M.native_event)
	wj.JS_SetPrototype(ctx, M.proto_IDBPlainEvent, evp)
	wj.JS_DefinePropertyValueStr(ctx, M.proto_IDBPlainEvent, "constructor", wj.JS_DupValue(ctx, M.native_event), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	wj.JS_FreeValue(ctx, evp)
	return wj.UNDEFINED
}

// a static operation of an interface (writable, configurable)
@(private = "file")
def_static :: proc "contextless" (ctx: ^wj.Context, cls: wj.JSValue, name: cstring, fn: wj.Native, length: i32) {
	wj.JS_DefinePropertyValueStr(ctx, cls, name, wj.new_cfunction(ctx, fn, name, length), wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE)
}

// The exports object web_idb.odin gets: { classes, factory, storage, buckets, hooks: { event, cleanup }, start }.
prelude_build :: proc "contextless" (ctx: ^wj.Context, host: wj.JSValue) -> wj.JSValue {
	M = {}
	M.ctx = ctx
	M.nextTask = 1
	M.failure_ctor = wj.UNDEFINED
	M.host = wj.JS_DupValue(ctx, host)
	hfn :: proc "contextless" (ctx: ^wj.Context, host: wj.JSValue, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, host, name) }
	M.host_call = hfn(ctx, host, "call")
	M.host_serialize = hfn(ctx, host, "serialize")
	M.host_deserialize = hfn(ctx, host, "deserialize")
	M.host_report = hfn(ctx, host, "report")
	M.host_drain = hfn(ctx, host, "drain")
	M.h_utf8 = hfn(ctx, host, "utf8")
	M.h_utf8d = hfn(ctx, host, "utf8d")
	M.h_key = hfn(ctx, host, "key")
	M.h_keyValue = hfn(ctx, host, "keyValue")
	M.h_cmp = hfn(ctx, host, "cmp")
	M.h_validPath = hfn(ctx, host, "validPath")
	M.h_pathKey = hfn(ctx, host, "pathKey")
	M.h_indexKeys = hfn(ctx, host, "indexKeys")
	M.h_canInject = hfn(ctx, host, "canInject")
	M.h_inject = hfn(ctx, host, "inject")
	M.h_execGet = hfn(ctx, host, "execGet")
	M.h_execCount = hfn(ctx, host, "execCount")
	M.h_execGetAll = hfn(ctx, host, "execGetAll")
	M.h_execPut = hfn(ctx, host, "execPut")
	M.h_execDelete = hfn(ctx, host, "execDelete")
	M.h_execClear = hfn(ctx, host, "execClear")
	M.h_execCursor = hfn(ctx, host, "execCursor")
	M.h_getDirectory = hfn(ctx, host, "getDirectory")
	M.h_setFailure = hfn(ctx, host, "setFailure")

	// the WeakMaps and Maps
	for wm in ([?]^wj.JSValue{
		&M.rangeState, &M.etState, &M.evState, &M.versions, &M.dbState, &M.txState, &M.reqState, &M.storeState,
		&M.indexState, &M.cursorState, &M.listState, &M.recordState, &M.factoryState, &M.smState, &M.sbmState, &M.sbState,
	}) { wm^ = weakmap_new(ctx) }
	for m in ([?]^wj.JSValue{ &M.conns, &M.txs, &M.openReqs, &M.listReqs, &M.tasks }) { m^ = map_new(ctx) }
	M.activeSet = set_new(ctx)
	M.vcDone = wj.JS_NewArray(ctx)

	// the Failure class and setFailure (so the host's exec helpers can throw it)
	fproto: wj.JSValue
	make_interface(ctx, "Failure", failure_ctor_fn, 2, &M.failure_ctor, &fproto)
	wj.JS_FreeValue(ctx, fproto)
	wj.JS_FreeValue(ctx, call1(ctx, M.h_setFailure, M.failure_ctor))

	// IDBEventTarget (internal base, never exposed): its prototype holds add/remove/dispatchEvent
	make_interface(ctx, "EventTarget", nil, 0, &M.cls_IDBEventTarget, &M.proto_IDBEventTarget)
	def_method(ctx, M.proto_IDBEventTarget, "addEventListener", et_add, 2)
	def_method(ctx, M.proto_IDBEventTarget, "removeEventListener", et_remove, 2)
	def_method(ctx, M.proto_IDBEventTarget, "dispatchEvent", et_dispatch, 1)

	// IDBRequest / IDBOpenDBRequest (event targets)
	make_interface(ctx, "IDBRequest", nil, 0, &M.cls_IDBRequest, &M.proto_IDBRequest)
	def_getset(ctx, M.proto_IDBRequest, "result", req_get_result, nil)
	def_getset(ctx, M.proto_IDBRequest, "error", req_get_error, nil)
	def_getset(ctx, M.proto_IDBRequest, "source", req_get_source, nil)
	def_getset(ctx, M.proto_IDBRequest, "transaction", req_get_transaction, nil)
	def_getset(ctx, M.proto_IDBRequest, "readyState", req_get_ready_state, nil)
	define_handlers(ctx, M.proto_IDBRequest, {0, 1})
	make_interface(ctx, "IDBOpenDBRequest", nil, 0, &M.cls_IDBOpenDBRequest, &M.proto_IDBOpenDBRequest)
	wj.JS_SetPrototype(ctx, M.proto_IDBOpenDBRequest, M.proto_IDBRequest)
	wj.JS_SetPrototype(ctx, M.cls_IDBOpenDBRequest, M.cls_IDBRequest)
	define_handlers(ctx, M.proto_IDBOpenDBRequest, {2, 3})

	// IDBFactory
	make_interface(ctx, "IDBFactory", nil, 0, &M.cls_IDBFactory, &M.proto_IDBFactory)
	def_method(ctx, M.proto_IDBFactory, "open", factory_open, 1)
	def_method(ctx, M.proto_IDBFactory, "deleteDatabase", factory_delete_database, 1)
	def_method(ctx, M.proto_IDBFactory, "databases", factory_databases, 0)
	def_method(ctx, M.proto_IDBFactory, "cmp", factory_cmp, 2)

	// IDBDatabase (event target)
	make_interface(ctx, "IDBDatabase", nil, 0, &M.cls_IDBDatabase, &M.proto_IDBDatabase)
	def_getset(ctx, M.proto_IDBDatabase, "name", db_get_name, nil)
	def_getset(ctx, M.proto_IDBDatabase, "version", db_get_version, nil)
	def_getset(ctx, M.proto_IDBDatabase, "objectStoreNames", db_get_objectStoreNames, nil)
	def_method(ctx, M.proto_IDBDatabase, "createObjectStore", db_createObjectStore, 1)
	def_method(ctx, M.proto_IDBDatabase, "deleteObjectStore", db_deleteObjectStore, 1)
	def_method(ctx, M.proto_IDBDatabase, "transaction", db_transaction, 1)
	def_method(ctx, M.proto_IDBDatabase, "close", db_close, 0)
	define_handlers(ctx, M.proto_IDBDatabase, {4, 5, 1, 6})

	// IDBTransaction (event target)
	make_interface(ctx, "IDBTransaction", nil, 0, &M.cls_IDBTransaction, &M.proto_IDBTransaction)
	def_getset(ctx, M.proto_IDBTransaction, "objectStoreNames", tx_get_objectStoreNames, nil)
	def_getset(ctx, M.proto_IDBTransaction, "mode", tx_get_mode, nil)
	def_getset(ctx, M.proto_IDBTransaction, "durability", tx_get_durability, nil)
	def_getset(ctx, M.proto_IDBTransaction, "db", tx_get_db, nil)
	def_getset(ctx, M.proto_IDBTransaction, "error", tx_get_error, nil)
	def_method(ctx, M.proto_IDBTransaction, "objectStore", tx_objectStore, 1)
	def_method(ctx, M.proto_IDBTransaction, "abort", tx_abort, 0)
	def_method(ctx, M.proto_IDBTransaction, "commit", tx_commit, 0)
	define_handlers(ctx, M.proto_IDBTransaction, {4, 7, 1})

	// IDBObjectStore
	make_interface(ctx, "IDBObjectStore", nil, 0, &M.cls_IDBObjectStore, &M.proto_IDBObjectStore)
	def_getset(ctx, M.proto_IDBObjectStore, "name", store_get_name, store_set_name)
	def_getset(ctx, M.proto_IDBObjectStore, "keyPath", store_get_keyPath, nil)
	def_getset(ctx, M.proto_IDBObjectStore, "indexNames", store_get_indexNames, nil)
	def_getset(ctx, M.proto_IDBObjectStore, "transaction", store_get_transaction, nil)
	def_getset(ctx, M.proto_IDBObjectStore, "autoIncrement", store_get_autoIncrement, nil)
	def_method(ctx, M.proto_IDBObjectStore, "put", store_put, 1)
	def_method(ctx, M.proto_IDBObjectStore, "add", store_add, 1)
	def_method(ctx, M.proto_IDBObjectStore, "delete", store_delete, 1)
	def_method(ctx, M.proto_IDBObjectStore, "clear", store_clear, 0)
	def_method(ctx, M.proto_IDBObjectStore, "get", store_get, 1)
	def_method(ctx, M.proto_IDBObjectStore, "getKey", store_getKey, 1)
	def_method(ctx, M.proto_IDBObjectStore, "getAll", store_getAll, 0)
	def_method(ctx, M.proto_IDBObjectStore, "getAllKeys", store_getAllKeys, 0)
	def_method(ctx, M.proto_IDBObjectStore, "getAllRecords", store_getAllRecords, 0)
	def_method(ctx, M.proto_IDBObjectStore, "count", store_count, 0)
	def_method(ctx, M.proto_IDBObjectStore, "openCursor", store_openCursor, 0)
	def_method(ctx, M.proto_IDBObjectStore, "openKeyCursor", store_openKeyCursor, 0)
	def_method(ctx, M.proto_IDBObjectStore, "index", store_index, 1)
	def_method(ctx, M.proto_IDBObjectStore, "createIndex", store_createIndex, 2)
	def_method(ctx, M.proto_IDBObjectStore, "deleteIndex", store_deleteIndex, 1)

	// IDBIndex
	make_interface(ctx, "IDBIndex", nil, 0, &M.cls_IDBIndex, &M.proto_IDBIndex)
	def_getset(ctx, M.proto_IDBIndex, "name", index_get_name, index_set_name)
	def_getset(ctx, M.proto_IDBIndex, "objectStore", index_get_objectStore, nil)
	def_getset(ctx, M.proto_IDBIndex, "keyPath", index_get_keyPath, nil)
	def_getset(ctx, M.proto_IDBIndex, "multiEntry", index_get_multiEntry, nil)
	def_getset(ctx, M.proto_IDBIndex, "unique", index_get_unique, nil)
	def_method(ctx, M.proto_IDBIndex, "get", index_get, 1)
	def_method(ctx, M.proto_IDBIndex, "getKey", index_getKey, 1)
	def_method(ctx, M.proto_IDBIndex, "getAll", index_getAll, 0)
	def_method(ctx, M.proto_IDBIndex, "getAllKeys", index_getAllKeys, 0)
	def_method(ctx, M.proto_IDBIndex, "getAllRecords", index_getAllRecords, 0)
	def_method(ctx, M.proto_IDBIndex, "count", index_count, 0)
	def_method(ctx, M.proto_IDBIndex, "openCursor", index_openCursor, 0)
	def_method(ctx, M.proto_IDBIndex, "openKeyCursor", index_openKeyCursor, 0)

	// IDBCursor / IDBCursorWithValue
	make_interface(ctx, "IDBCursor", nil, 0, &M.cls_IDBCursor, &M.proto_IDBCursor)
	def_getset(ctx, M.proto_IDBCursor, "source", cursor_get_source, nil)
	def_getset(ctx, M.proto_IDBCursor, "direction", cursor_get_direction, nil)
	def_getset(ctx, M.proto_IDBCursor, "key", cursor_get_key, nil)
	def_getset(ctx, M.proto_IDBCursor, "primaryKey", cursor_get_primaryKey, nil)
	def_getset(ctx, M.proto_IDBCursor, "request", cursor_get_request, nil)
	def_method(ctx, M.proto_IDBCursor, "advance", cursor_advance, 1)
	def_method(ctx, M.proto_IDBCursor, "continue", cursor_continue, 0)
	def_method(ctx, M.proto_IDBCursor, "continuePrimaryKey", cursor_continuePrimaryKey, 2)
	def_method(ctx, M.proto_IDBCursor, "update", cursor_update, 1)
	def_method(ctx, M.proto_IDBCursor, "delete", cursor_delete, 0)
	make_interface(ctx, "IDBCursorWithValue", nil, 0, &M.cls_IDBCursorWithValue, &M.proto_IDBCursorWithValue)
	wj.JS_SetPrototype(ctx, M.proto_IDBCursorWithValue, M.proto_IDBCursor)
	wj.JS_SetPrototype(ctx, M.cls_IDBCursorWithValue, M.cls_IDBCursor)
	def_getset(ctx, M.proto_IDBCursorWithValue, "value", cursorwv_get_value, nil)

	// IDBKeyRange
	make_interface(ctx, "IDBKeyRange", nil, 0, &M.cls_IDBKeyRange, &M.proto_IDBKeyRange)
	def_getset(ctx, M.proto_IDBKeyRange, "lower", range_get_lower, nil)
	def_getset(ctx, M.proto_IDBKeyRange, "upper", range_get_upper, nil)
	def_getset(ctx, M.proto_IDBKeyRange, "lowerOpen", range_get_lowerOpen, nil)
	def_getset(ctx, M.proto_IDBKeyRange, "upperOpen", range_get_upperOpen, nil)
	def_method(ctx, M.proto_IDBKeyRange, "includes", range_includes, 1)
	def_static(ctx, M.cls_IDBKeyRange, "only", range_only, 1)
	def_static(ctx, M.cls_IDBKeyRange, "lowerBound", range_lower_bound, 1)
	def_static(ctx, M.cls_IDBKeyRange, "upperBound", range_upper_bound, 1)
	def_static(ctx, M.cls_IDBKeyRange, "bound", range_bound, 2)

	// IDBVersionChangeEvent
	make_interface(ctx, "IDBVersionChangeEvent", version_event_ctor, 1, &M.cls_IDBVersionChangeEvent, &M.proto_IDBVersionChangeEvent)
	def_getset(ctx, M.proto_IDBVersionChangeEvent, "oldVersion", vce_get_old, nil)
	def_getset(ctx, M.proto_IDBVersionChangeEvent, "newVersion", vce_get_new, nil)
	install_event_overrides(ctx, M.proto_IDBVersionChangeEvent)

	// IDBPlainEvent (internal): events IDB fires; its prototype has the overrides
	make_interface(ctx, "Event", plain_event_ctor, 1, &M.cls_IDBPlainEvent, &M.proto_IDBPlainEvent)
	install_event_overrides(ctx, M.proto_IDBPlainEvent)

	// IDBRecord
	make_interface(ctx, "IDBRecord", nil, 0, &M.cls_IDBRecord, &M.proto_IDBRecord)
	def_getset_magic(ctx, M.proto_IDBRecord, "key", record_get, nil, 0)
	def_getset_magic(ctx, M.proto_IDBRecord, "primaryKey", record_get, nil, 1)
	def_getset_magic(ctx, M.proto_IDBRecord, "value", record_get, nil, 2)

	// DOMStringList
	make_interface(ctx, "DOMStringList", nil, 0, &M.cls_DOMStringList, &M.proto_DOMStringList)
	def_getset(ctx, M.proto_DOMStringList, "length", list_get_length, nil)
	def_method(ctx, M.proto_DOMStringList, "item", list_item, 1)
	def_method(ctx, M.proto_DOMStringList, "contains", list_contains, 1)
	{   // DOMStringList.prototype[Symbol.iterator] = Array.prototype[Symbol.iterator]
		array := g_prop(ctx, "Array")
		arrp := wj.JS_GetPropertyStr(ctx, array, "prototype")
		a := symbol_atom(ctx, "iterator")
		wj.JS_DefinePropertyValue(ctx, M.proto_DOMStringList, a, wj.JS_GetProperty(ctx, arrp, a), wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE)
		wj.JS_FreeAtom(ctx, a)
		wj.JS_FreeValue(ctx, arrp)
		wj.JS_FreeValue(ctx, array)
	}

	// StorageManager / StorageBucketManager / StorageBucket
	make_interface(ctx, "StorageManager", nil, 0, &M.cls_StorageManager, &M.proto_StorageManager)
	def_method(ctx, M.proto_StorageManager, "estimate", sm_estimate, 0)
	def_method(ctx, M.proto_StorageManager, "persist", sm_persist, 0)
	def_method(ctx, M.proto_StorageManager, "persisted", sm_persisted, 0)
	def_method(ctx, M.proto_StorageManager, "getDirectory", sm_getDirectory, 0)
	make_interface(ctx, "StorageBucketManager", nil, 0, &M.cls_StorageBucketManager, &M.proto_StorageBucketManager)
	def_method(ctx, M.proto_StorageBucketManager, "open", sbm_open, 1)
	def_method(ctx, M.proto_StorageBucketManager, "keys", sbm_keys, 0)
	def_method(ctx, M.proto_StorageBucketManager, "delete", sbm_delete, 1)
	make_interface(ctx, "StorageBucket", nil, 0, &M.cls_StorageBucket, &M.proto_StorageBucket)
	def_getset(ctx, M.proto_StorageBucket, "name", sb_get_name, nil)
	def_getset(ctx, M.proto_StorageBucket, "indexedDB", sb_get_indexedDB, nil)
	def_method(ctx, M.proto_StorageBucket, "persist", sb_persist, 0)
	def_method(ctx, M.proto_StorageBucket, "persisted", sb_persisted, 0)
	def_method(ctx, M.proto_StorageBucket, "estimate", sb_estimate, 0)
	def_method(ctx, M.proto_StorageBucket, "durability", sb_durability, 0)
	def_method(ctx, M.proto_StorageBucket, "setExpires", sb_setExpires, 1)
	def_method(ctx, M.proto_StorageBucket, "expires", sb_expires, 0)
	def_method(ctx, M.proto_StorageBucket, "getDirectory", sb_getDirectory, 0)

	// exposeMembers + Symbol.toStringTag for each exposed interface (order as the old `all` array)
	Exposed :: struct { cls, proto: wj.JSValue, tag: cstring, in_classes: bool }
	all := [?]Exposed{
		{ M.cls_IDBRequest, M.proto_IDBRequest, "IDBRequest", true },
		{ M.cls_IDBOpenDBRequest, M.proto_IDBOpenDBRequest, "IDBOpenDBRequest", true },
		{ M.cls_IDBFactory, M.proto_IDBFactory, "IDBFactory", true },
		{ M.cls_IDBDatabase, M.proto_IDBDatabase, "IDBDatabase", true },
		{ M.cls_IDBTransaction, M.proto_IDBTransaction, "IDBTransaction", true },
		{ M.cls_IDBObjectStore, M.proto_IDBObjectStore, "IDBObjectStore", true },
		{ M.cls_IDBIndex, M.proto_IDBIndex, "IDBIndex", true },
		{ M.cls_IDBCursor, M.proto_IDBCursor, "IDBCursor", true },
		{ M.cls_IDBCursorWithValue, M.proto_IDBCursorWithValue, "IDBCursorWithValue", true },
		{ M.cls_IDBKeyRange, M.proto_IDBKeyRange, "IDBKeyRange", true },
		{ M.cls_IDBVersionChangeEvent, M.proto_IDBVersionChangeEvent, "IDBVersionChangeEvent", true },
		{ M.cls_IDBRecord, M.proto_IDBRecord, "IDBRecord", true },
		{ M.cls_DOMStringList, M.proto_DOMStringList, "DOMStringList", false },
		{ M.cls_StorageManager, M.proto_StorageManager, "StorageManager", true },
		{ M.cls_StorageBucketManager, M.proto_StorageBucketManager, "StorageBucketManager", true },
		{ M.cls_StorageBucket, M.proto_StorageBucket, "StorageBucket", true },
	}
	classes := wj.JS_NewObject(ctx)
	for e in all {
		expose_members(ctx, e.cls, e.proto, e.tag)
		if e.in_classes { wj.JS_SetPropertyStr(ctx, classes, e.tag, wj.JS_DupValue(ctx, e.cls)) }
	}
	M.classes = classes

	// the default factory, the storage and bucket managers
	M.factory = obj_create(ctx, M.proto_IDBFactory)
	{
		fs := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, fs, "bucket", wj.new_string(ctx, ""))
		wm_set(ctx, M.factoryState, M.factory, fs)
		wj.JS_FreeValue(ctx, fs)
	}
	M.storage = obj_create(ctx, M.proto_StorageManager)
	wm_set(ctx, M.smState, M.storage, wj.TRUE)
	M.buckets = obj_create(ctx, M.proto_StorageBucketManager)
	wm_set(ctx, M.sbmState, M.buckets, wj.TRUE)

	// hooks: { event, cleanup }
	M.hooks = wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, M.hooks, "event", wj.new_cfunction(ctx, hook_event, "event", 0))
	wj.JS_SetPropertyStr(ctx, M.hooks, "cleanup", wj.new_cfunction(ctx, hook_cleanup, "cleanup", 0))

	// exports = { classes, factory, storage, buckets, hooks, start }
	exports := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, exports, "classes", wj.JS_DupValue(ctx, M.classes))
	wj.JS_SetPropertyStr(ctx, exports, "factory", wj.JS_DupValue(ctx, M.factory))
	wj.JS_SetPropertyStr(ctx, exports, "storage", wj.JS_DupValue(ctx, M.storage))
	wj.JS_SetPropertyStr(ctx, exports, "buckets", wj.JS_DupValue(ctx, M.buckets))
	wj.JS_SetPropertyStr(ctx, exports, "hooks", wj.JS_DupValue(ctx, M.hooks))
	wj.JS_SetPropertyStr(ctx, exports, "start", wj.new_cfunction(ctx, idb_start, "start", 0))
	M.exports = wj.JS_DupValue(ctx, exports)
	M.built = true
	return exports
}
