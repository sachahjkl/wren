// model_storage.odin: navigator.storage and navigator.storageBuckets. The StorageManager / StorageBucketManager /
// StorageBucket singletons and their promise-returning methods. Ported from web_idb_prelude.c (same names).
package idb

import "../wj"

// bucketCall(op, w): call(op) with what w holds; a reader after the status byte, its reply kept alive in `keep`.
// False with a DOMException thrown when the browser failed.
@(private = "file")
bucket_call :: proc "contextless" (ctx: ^wj.Context, op: i32, w: ^Wr) -> (r: Rd, keep: wj.JSValue, ok: bool) {
	rep := host_call1(ctx, op, wr_u8array(ctx, w))
	wr_free(w)
	if wj.is_exception(rep) { return }
	p, got := reply_bytes(ctx, rep)
	if !got { wj.JS_FreeValue(ctx, rep); return }
	if len(p) > 0 && p[0] != 0 {
		s := i32(p[0])
		wj.JS_FreeValue(ctx, rep)
		throw_fail(ctx, s, nil)
		return
	}
	return Rd{ p = p, pos = 1 }, rep, true
}

@(private = "file")
str_bytes :: #force_inline proc "contextless" (s: string) -> []u8 { return transmute([]u8)s }

// estimateOf(bucket): { usage, quota }
@(private = "file")
estimate_of :: proc "contextless" (ctx: ^wj.Context, bucket: string) -> wj.JSValue {
	w := Wr{ ctx = ctx }
	wr_bytes(&w, str_bytes(bucket))
	r, keep, ok := bucket_call(ctx, OP_ESTIMATE, &w)
	if !ok { return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, o, "usage", wj.new_int64(ctx, i64(rd_uv(&r))))
	wj.JS_SetPropertyStr(ctx, o, "quota", wj.new_int64(ctx, i64(rd_uv(&r))))
	wj.JS_FreeValue(ctx, keep)
	return o
}

// persistOf(bucket, request): whether the bucket is persistent (asking for it when `request`); -1 with an exception
@(private = "file")
persist_of :: proc "contextless" (ctx: ^wj.Context, bucket: string, request: bool) -> i32 {
	w := Wr{ ctx = ctx }
	wr_bytes(&w, str_bytes(bucket))
	wr_u8(&w, request ? 1 : 0)
	r, keep, ok := bucket_call(ctx, OP_PERSIST, &w)
	if !ok { return -1 }
	v := rd_u8(&r) != 0
	wj.JS_FreeValue(ctx, keep)
	return v ? 1 : 0
}

// a promise resolved with `v` (taken)
@(private = "file")
resolved :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	p := wj.web_promise_resolved(ctx, v)
	wj.JS_FreeValue(ctx, v)
	return p
}

// the state of `this` in `m`, checked; false (an exception pending) when it is not one of ours
@(private = "file")
check_state :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, this_val: wj.JSValue) -> bool {
	s := state_of(ctx, m, this_val)
	if wj.is_exception(s) { return false }
	wj.JS_FreeValue(ctx, s)
	return true
}

// ---- StorageManager ----

sm_estimate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !check_state(ctx, M.smState, this_val) { return wj.web_promise_reject_pending(ctx) }
	e := estimate_of(ctx, "")
	if wj.is_exception(e) { return wj.web_promise_reject_pending(ctx) }
	return resolved(ctx, e)
}

@(private = "file")
sm_persist_common :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, request: bool) -> wj.JSValue {
	if !check_state(ctx, M.smState, this_val) { return wj.web_promise_reject_pending(ctx) }
	r := persist_of(ctx, "", request)
	if r < 0 { return wj.web_promise_reject_pending(ctx) }
	return resolved(ctx, wj.new_bool(r != 0))
}
sm_persist   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return sm_persist_common(ctx, this_val, true) }
sm_persisted :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return sm_persist_common(ctx, this_val, false) }

sm_getDirectory :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !check_state(ctx, M.smState, this_val) { return wj.web_promise_reject_pending(ctx) }
	b := wj.new_string(ctx, "")
	r := call1(ctx, M.h_getDirectory, b)
	wj.JS_FreeValue(ctx, b)
	return r
}

// ---- StorageBucketManager ----

// a bucket name: 1 to 63 of [a-z0-9_-], starting with [a-z0-9]
@(private = "file")
valid_bucket_name :: proc "contextless" (n: string) -> bool {
	if len(n) == 0 || len(n) > 63 { return false }
	for c, i in transmute([]u8)n {
		switch c {
		case 'a' ..= 'z', '0' ..= '9':
		case '_', '-': if i == 0 { return false }
		case: return false
		}
	}
	return true
}

@(private = "file")
make_bucket :: proc "contextless" (ctx: ^wj.Context, name: string, persisted: bool, durability: string, expires: f64) -> wj.JSValue {
	b := obj_create(ctx, M.proto_StorageBucket)
	factory := obj_create(ctx, M.proto_IDBFactory)
	fs := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, fs, "bucket", wj.new_string_len(ctx, name))
	wm_set(ctx, M.factoryState, factory, fs)
	wj.JS_FreeValue(ctx, fs)
	s := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, s, "name", wj.new_string_len(ctx, name))
	wj.JS_SetPropertyStr(ctx, s, "persisted", wj.new_bool(persisted))
	wj.JS_SetPropertyStr(ctx, s, "durability", wj.new_string_len(ctx, durability))
	wj.JS_SetPropertyStr(ctx, s, "expires", wj.new_float64(ctx, expires))
	wj.JS_SetPropertyStr(ctx, s, "factory", factory)
	wm_set(ctx, M.sbState, b, s)
	wj.JS_FreeValue(ctx, s)
	return b
}

// The bucket name argument of open / delete: String(v), checked (TypeError otherwise). Free with free_cstring.
@(private = "file")
bucket_name_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, what: cstring) -> (cstring, bool) {
	nv := to_str(ctx, v)
	n := wj.to_cstring(ctx, nv)
	wj.JS_FreeValue(ctx, nv)
	if n == nil { return nil, false }
	if !valid_bucket_name(string(n)) {
		wj.free_cstring(ctx, n)
		wj.JS_ThrowTypeError(ctx, "Failed to execute '%s' on 'StorageBucketManager': The bucket name is not valid.", what)
		return nil, false
	}
	return n, true
}

DURABILITIES := [2]string{ "strict", "relaxed" }

sbm_open :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !check_state(ctx, M.sbmState, this_val) { return wj.web_promise_reject_pending(ctx) }
	if !arity(ctx, 1, argc, "open", "StorageBucketManager") { return wj.web_promise_reject_pending(ctx) }
	n, ok := bucket_name_arg(ctx, argv[0], "open")
	if !ok { return wj.web_promise_reject_pending(ctx) }
	defer wj.free_cstring(ctx, n)
	persisted := false
	durability := ""
	expires := f64(-1)
	options := wj.arg(argc, argv, 1)
	if !wj.is_nullish(options) {
		if !wj.is_object(options) {
			type_error(ctx, "The options argument is not of type 'StorageBucketOptions'.")
			return wj.web_promise_reject_pending(ctx)
		}
		pv := wj.JS_GetPropertyStr(ctx, options, "persisted")
		persisted = wj.JS_ToBool(ctx, pv) != 0
		wj.JS_FreeValue(ctx, pv)
		dur := wj.JS_GetPropertyStr(ctx, options, "durability")
		if !wj.is_undefined(dur) {
			i, valid := check_enum(ctx, dur, DURABILITIES[:], "StorageBucketDurability")
			if !valid { wj.JS_FreeValue(ctx, dur); return wj.web_promise_reject_pending(ctx) }
			durability = DURABILITIES[i]
		}
		wj.JS_FreeValue(ctx, dur)
		ex := wj.JS_GetPropertyStr(ctx, options, "expires")
		if !wj.is_nullish(ex) { wj.JS_ToFloat64(ctx, &expires, ex) }
		wj.JS_FreeValue(ctx, ex)
	}
	w := Wr{ ctx = ctx }
	wr_u8(&w, 0)
	wr_bytes(&w, str_bytes(string(n)))
	wr_u8(&w, persisted ? 1 : 0)
	wr_bytes(&w, str_bytes(durability))
	wr_f64(&w, expires)
	r, keep, called := bucket_call(ctx, OP_BUCKETS, &w)
	if !called { return wj.web_promise_reject_pending(ctx) }
	rp := rd_u8(&r) != 0
	rdur := rd_bytes(&r)
	rex := rd_f64(&r)
	b := make_bucket(ctx, string(n), rp, string(rdur), rex)
	wj.JS_FreeValue(ctx, keep)
	return resolved(ctx, b)
}

sbm_keys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !check_state(ctx, M.sbmState, this_val) { return wj.web_promise_reject_pending(ctx) }
	w := Wr{ ctx = ctx }
	wr_u8(&w, 1)
	r, keep, ok := bucket_call(ctx, OP_BUCKETS, &w)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	n := rd_uv(&r)
	out := wj.JS_NewArray(ctx)
	k: u32
	for i: u64 = 0; i < n && !r.bad; i += 1 {
		nm := rd_bytes(&r)
		if string(nm) == "default" { continue }
		wj.JS_SetPropertyUint32(ctx, out, k, wj.new_string_len(ctx, nm))
		k += 1
	}
	wj.JS_FreeValue(ctx, keep)
	return resolved(ctx, out)
}

sbm_delete :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !check_state(ctx, M.sbmState, this_val) { return wj.web_promise_reject_pending(ctx) }
	if !arity(ctx, 1, argc, "delete", "StorageBucketManager") { return wj.web_promise_reject_pending(ctx) }
	n, ok := bucket_name_arg(ctx, argv[0], "delete")
	if !ok { return wj.web_promise_reject_pending(ctx) }
	w := Wr{ ctx = ctx }
	wr_u8(&w, 2)
	wr_bytes(&w, str_bytes(string(n)))
	wj.free_cstring(ctx, n)
	_, keep, called := bucket_call(ctx, OP_BUCKETS, &w)
	if !called { return wj.web_promise_reject_pending(ctx) }
	wj.JS_FreeValue(ctx, keep)
	return wj.web_promise_resolved(ctx, wj.UNDEFINED)
}

// ---- StorageBucket ----

@(private = "file")
sb_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring) -> wj.JSValue {
	B := state_of(ctx, M.sbState, this_val)
	if wj.is_exception(B) { return B }
	r := pget(ctx, B, name)
	wj.JS_FreeValue(ctx, B)
	return r
}
sb_get_name      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return sb_field(ctx, this_val, "name") }
sb_get_indexedDB :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return sb_field(ctx, this_val, "factory") }

// The bucket's state and its name (free both with sb_release); false with an exception pending.
@(private = "file")
Sb :: struct { B, nm: wj.JSValue, n: cstring }
@(private = "file")
sb_acquire :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> (s: Sb, ok: bool) {
	s.B = state_of(ctx, M.sbState, this_val)
	if wj.is_exception(s.B) { return }
	s.nm = pget(ctx, s.B, "name")
	s.n = wj.to_cstring(ctx, s.nm)
	return s, true
}
@(private = "file")
sb_name :: #force_inline proc "contextless" (s: Sb) -> string { return s.n != nil ? string(s.n) : "" }
@(private = "file")
sb_release :: proc "contextless" (ctx: ^wj.Context, s: Sb) {
	if s.n != nil { wj.free_cstring(ctx, s.n) }
	wj.JS_FreeValue(ctx, s.nm)
	wj.JS_FreeValue(ctx, s.B)
}

@(private = "file")
sb_persist_common :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, request: bool) -> wj.JSValue {
	s, ok := sb_acquire(ctx, this_val)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	defer sb_release(ctx, s)
	r := persist_of(ctx, sb_name(s), request)
	if r < 0 { return wj.web_promise_reject_pending(ctx) }
	if request { pset(ctx, s.B, "persisted", wj.new_bool(r != 0)) }
	return resolved(ctx, wj.new_bool(r != 0))
}
sb_persist   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return sb_persist_common(ctx, this_val, true) }
sb_persisted :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return sb_persist_common(ctx, this_val, false) }

sb_estimate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s, ok := sb_acquire(ctx, this_val)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	e := estimate_of(ctx, sb_name(s))
	sb_release(ctx, s)
	if wj.is_exception(e) { return wj.web_promise_reject_pending(ctx) }
	return resolved(ctx, e)
}

sb_durability :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := sb_field(ctx, this_val, "durability")
	if wj.is_exception(d) { return wj.web_promise_reject_pending(ctx) }
	return resolved(ctx, d)
}

sb_setExpires :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s, acquired := sb_acquire(ctx, this_val)
	if !acquired { return wj.web_promise_reject_pending(ctx) }
	ms: f64
	wj.JS_ToFloat64(ctx, &ms, wj.arg(argc, argv, 0))
	pset(ctx, s.B, "expires", wj.new_float64(ctx, ms))
	w := Wr{ ctx = ctx }
	wr_u8(&w, 3)
	wr_bytes(&w, str_bytes(sb_name(s)))
	wr_f64(&w, ms)
	_, keep, ok := bucket_call(ctx, OP_BUCKETS, &w)
	sb_release(ctx, s)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	wj.JS_FreeValue(ctx, keep)
	return wj.web_promise_resolved(ctx, wj.UNDEFINED)
}

sb_expires :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	e := sb_field(ctx, this_val, "expires")
	if wj.is_exception(e) { return wj.web_promise_reject_pending(ctx) }
	ex: f64
	wj.JS_ToFloat64(ctx, &ex, e)
	wj.JS_FreeValue(ctx, e)
	return resolved(ctx, ex < 0 ? wj.NULL : wj.new_float64(ctx, ex))
}

sb_getDirectory :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	nm := sb_field(ctx, this_val, "name")
	if wj.is_exception(nm) { return wj.web_promise_reject_pending(ctx) }
	r := call1(ctx, M.h_getDirectory, nm)
	wj.JS_FreeValue(ctx, nm)
	return r
}
