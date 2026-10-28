// shared_workers.odin: shared workers (HTML "shared workers"), from both sides: a document (new SharedWorker(url, name
// | {name, type, credentials, extendedLifetime}) connects to the shared worker of (storage key, URL, name); worker.port
// is a MessagePort), and the worker's realm (each connection fires `connect`, a MessageEvent whose ports[0]/source is
// the new port). Ported from native/js/runtime/shared_workers.c; same wjr_* symbols, same wj_shared_connect export.
// web_port_remote (web_message.odin) and web_keep_worker (workers.odin) are Odin; web_message_event_named (web_socket.odin) and
// web_blob_url_bytes (web_blob.odin) are Odin too.
package odin_glue

import "../odin/wj"




// enum wj.wr_WorkerType
WORKER_TYPE_CLASSIC :: i32(0)
WORKER_TYPE_MODULE  :: i32(1)

@(private = "file")
Shared_Impl :: struct {
	port: wj.JSValue,
}

@(private = "file") shared_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^Shared_Impl)(p).port)
	wj.libc_free(p)
}
@(private = "file") shared_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Shared_Impl)(p).port, mark_func) }

@(private = "file") iface_sharedworker := i32(-2)
@(private = "file") sharedworker_iface :: proc "c" () -> i32 {
	if iface_sharedworker == -2 { iface_sharedworker = wj.iface("SharedWorker") }
	return iface_sharedworker
}

// an enum member of SharedWorkerOptions: -1 with a TypeError pending when not one of `names`
@(private = "file") enum_member :: proc "c" (ctx: ^wj.Context, opt: wj.JSValue, member: cstring, names: []cstring, def: i32) -> i32 {
	v: wj.JSValue
	if !wj.web_dict_get(ctx, opt, member, &v) { return -1 }
	if wj.is_undefined(v) { return def }
	s := wj.to_cstring(ctx, v)
	wj.JS_FreeValue(ctx, v)
	if s == nil { return -1 }
	found := i32(-1)
	for name, i in names { if string(s) == string(name) { found = i32(i); break } }
	wj.free_cstring(ctx, s)
	if found < 0 { wj.JS_ThrowTypeError(ctx, "Failed to construct 'SharedWorker': The provided value is not a valid enum value of type %s.", member) }
	return found
}

@(export, link_name = "wjr_SharedWorker_constructor")
wjr_SharedWorker_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor SharedWorker requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "SharedWorker", 1, argc) }
	url: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &url) { return wj.EXCEPTION }
	name := wj.Str{ ptr = raw_empty_sw(), len = 0, owned = false }
	type := i32(0)
	extended := false
	opt := wj.arg(argc, argv, 1)

	fail :: proc "c" (ctx: ^wj.Context, url: ^wj.Str, name: ^wj.Str) -> wj.JSValue {
		wj.wj_str_free(ctx, url)
		wj.wj_str_free(ctx, name)
		return wj.EXCEPTION
	}

	// (DOMString or SharedWorkerOptions): undefined, null and objects are the dictionary, anything else a name
	if wj.is_undefined(opt) || wj.is_null(opt) || wj.is_object(opt) {
		v: wj.JSValue
		if !wj.web_dict_check(ctx, opt, "SharedWorkerOptions") { return fail(ctx, &url, &name) }
		if !wj.web_dict_get(ctx, opt, "credentials", &v) { return fail(ctx, &url, &name) }
		if !wj.is_undefined(v) {
			creds := []cstring{ "omit", "same-origin", "include" }
			wj.JS_FreeValue(ctx, v)
			if enum_member(ctx, opt, "credentials", creds, 1) < 0 { return fail(ctx, &url, &name) }
		}
		if !wj.web_dict_get(ctx, opt, "extendedLifetime", &v) { return fail(ctx, &url, &name) }
		extended = wj.JS_ToBool(ctx, v) > 0
		wj.JS_FreeValue(ctx, v)
		if !wj.web_dict_get(ctx, opt, "name", &v) { return fail(ctx, &url, &name) }
		if !wj.is_undefined(v) {
			ok := wj.wj_to_str(ctx, v, &name, 0, "")
			wj.JS_FreeValue(ctx, v)
			if !ok { return fail(ctx, &url, &name) }
		}
		types := []cstring{ "classic", "module" }
		type = enum_member(ctx, opt, "type", types, 0)
		if type < 0 { return fail(ctx, &url, &name) }
	} else if !wj.wj_to_str(ctx, opt, &name, 0, "") {
		return fail(ctx, &url, &name)
	}

	h := u64(0)
	st: i32
	bp: [^]u8
	bn: uint
	if web_blob_url_bytes(ctx, url.ptr, url.len, &bp, &bn) {
		st = wj.wr_SharedWorker_connectBytes(url.ptr, u32(url.len), name.ptr, u32(name.len),
			type == 1 ? WORKER_TYPE_MODULE : WORKER_TYPE_CLASSIC, extended ? 1 : 0, bp != nil ? bp : raw_empty_sw(), u32(bn), &h)
	} else {
		st = wj.wr_SharedWorker_connect(url.ptr, u32(url.len), name.ptr, u32(name.len),
			type == 1 ? WORKER_TYPE_MODULE : WORKER_TYPE_CLASSIC, extended ? 1 : 0, &h)
	}
	wj.wj_str_free(ctx, &url)
	wj.wj_str_free(ctx, &name)
	if st < 0 { return wj.wj_throw_status(ctx, st, "SharedWorker") }
	impl := (^Shared_Impl)(wj.libc_calloc(1, size_of(Shared_Impl)))
	if impl == nil { wj.wr_Object_release(h); return wj.JS_ThrowOutOfMemory(ctx) }
	impl.port = wj.UNDEFINED
	obj := wj.wj_wrap_owned(ctx, h, sharedworker_iface(), new_target)
	if wj.is_exception(obj) { wj.libc_free(impl); return obj }
	wj.web_set_impl(obj, impl, shared_free, shared_mark)
	port := web_port_remote(ctx, wj.wr_SharedWorker_portEnd(h))
	if wj.is_exception(port) { wj.JS_FreeValue(ctx, obj); return port }
	impl.port = port
	web_keep_worker(ctx, obj)   // until the browser says its worker is gone: it may still get error
	return obj
}

@(export, link_name = "wjr_SharedWorker_get_port")
wjr_SharedWorker_get_port :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	s := (^Shared_Impl)(wj.web_this_impl(ctx, this_val, sharedworker_iface()))
	return s != nil ? wj.JS_DupValue(ctx, s.port) : wj.EXCEPTION
}

// The browser: connections wait for this shared worker (SharedWorkerGlobalScope_takeConnection).
@(export, link_name = "wj_shared_connect")
wj_shared_connect :: proc "c" () {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	for {
		end := wj.wr_SharedWorkerGlobalScope_takeConnection()
		if end == 0 { break }
		port := web_port_remote(ctx, end)
		if wj.is_exception(port) { wj.wj_report_pending(ctx); continue }
		ports := wj.JS_NewArray(ctx)
		wj.JS_SetPropertyUint32(ctx, ports, 0, wj.JS_DupValue(ctx, port))
		data := wj.JS_NewString(ctx, "")
		ev := web_message_event_named(ctx, "connect", data, "", port, ports)
		wj.JS_FreeValue(ctx, data)
		wj.JS_FreeValue(ctx, ports)
		wj.JS_FreeValue(ctx, port)
		if wj.is_exception(ev) { wj.wj_report_pending(ctx); continue }
		wj.web_event_fire(ctx, wj.realm_global(), ev)
		wj.JS_FreeValue(ctx, ev)
	}
}

@(private = "file") empty_byte_sw: u8
@(private = "file") raw_empty_sw :: #force_inline proc "contextless" () -> [^]u8 { return &empty_byte_sw }
