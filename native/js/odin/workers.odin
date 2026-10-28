// workers.odin: dedicated workers whose script is JavaScript (HTML "workers"), from both sides:
//
//   * the page: new Worker(url, {name, type}), worker.postMessage(message, transfer), worker.terminate();
//   * the worker's realm (its own engine instance, on its own thread: src/page/js_workers.odin):
//     postMessage(message, transfer), importScripts(...urls);
//   * both: MessageEvent.data, the message structured-cloned (clone.odin) and carried by the browser as bytes, with the
//     MessagePorts of the transfer list shipped as port ends (web_message.odin).
//
// A Worker object stays alive while its worker may still send it events (HTML: a worker the page can still hear from
// is not collected): the realm holds it until terminate(), or until the browser says the worker is gone. A SharedWorker
// object is held the same way (web_keep_worker, shared_workers.odin). Ported from native/js/runtime/workers.c; same
// wjr_* symbols and exports (wj_worker_gone).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") nothing: abi.Nothing

// the Worker / SharedWorker objects of this realm that are running (counted)
@(private = "file") live_workers: [dynamic]wj.JSValue

@(private = "file")
let_go :: proc(ctx: ^wj.Context, handle: u64) {
	for w, i in live_workers {
		if wj.obj_handle(w) != handle { continue }
		unordered_remove(&live_workers, i)
		wj.JS_FreeValue(ctx, w)
		return
	}
}

// A Worker or SharedWorker object stays alive while its worker runs (until wj_worker_gone or terminate()).
@(export, link_name = "web_keep_worker")
web_keep_worker :: proc "c" (ctx: ^wj.Context, w: wj.JSValue) {
	context = m4_context()
	append(&live_workers, wj.JS_DupValue(ctx, w))
}

// The browser: the worker of `handle` is gone (it closed itself, failed to start, or its thread ended).
@(export, link_name = "wj_worker_gone")
wj_worker_gone :: proc "c" (handle: u64) {
	context = m4_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	let_go(ctx, handle)
}

// {transfer} of StructuredSerializeOptions, or a transfer sequence (the legacy overload); counted.
@(private = "file")
transfer_argument :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> (wj.JSValue, bool) {
	opt := wj.arg(argc, argv, 1)
	if wj.is_nullish(opt) { return wj.UNDEFINED, true }
	if !wj.is_object(opt) {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'postMessage': The provided value is not of type 'StructuredSerializeOptions'.")
		return wj.UNDEFINED, false
	}
	if wj.JS_IsArray(opt) { return wj.JS_DupValue(ctx, opt), true }
	// any other iterable is a sequence too; an object with a transfer member is the options dictionary
	t := wj.JS_GetPropertyStr(ctx, opt, "transfer")
	if wj.is_exception(t) { return wj.UNDEFINED, false }
	return t, true
}

// A posted message: its serialization (a libc block) and the ends of the MessagePorts it ships (a libc block).
@(private = "file")
Message :: struct { bytes: []u8, ends: []u64 }

@(private = "file")
message_free :: proc "contextless" (m: Message) {
	wj.libc_free(raw_data(m.bytes))
	wj.libc_free(raw_data(m.ends))
}

// The message of postMessage(message, transfer), serialized with its ports shipped; false with an exception pending.
@(private = "file")
serialize_message :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> (Message, bool) {
	if argc < 1 { wj.wj_throw_arity(ctx, "postMessage", 1, argc); return {}, false }
	transfer, ok := transfer_argument(ctx, argc, argv)
	if !ok { return {}, false }
	ports := wj.UNDEFINED
	n: uint
	bytes := wj_clone_serialize_ports(ctx, argv[0], transfer, &n, &ports)
	wj.JS_FreeValue(ctx, transfer)
	defer wj.JS_FreeValue(ctx, ports)
	if bytes == nil { return {}, false }
	ends, shipped := ship_ports(ctx, ports)
	if !shipped { wj.libc_free(bytes); return {}, false }
	return Message{bytes[:n], ends}, true
}

// ---- the page's side ----

// WorkerOptions.type: -1 with a TypeError pending for a value that is not a WorkerType
@(private = "file")
worker_type :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> (api_decl.WorkerType, bool) {
	c, s := to_text(ctx, t)
	if c == nil { return .Classic, false }
	defer wj.free_cstring(ctx, c)
	switch s {
	case "classic": return .Classic, true
	case "module":  return .Module, true
	}
	wj.JS_ThrowTypeError(ctx, "Failed to construct 'Worker': The provided value is not a valid enum value of type WorkerType.")
	return .Classic, false
}

@(export, link_name = "wjr_Worker_constructor")
wjr_Worker_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor Worker requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Worker", 1, argc) }
	url, name: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &url, wj.STR_USV, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &url)
	defer wj.wj_str_free(ctx, &name)
	type := api_decl.WorkerType.Classic
	if opt := wj.arg(argc, argv, 1); wj.is_object(opt) {
		n := wj.JS_GetPropertyStr(ctx, opt, "name")
		if wj.is_exception(n) { return n }
		ok := wj.is_undefined(n) || wj.wj_to_str(ctx, n, &name, 0, "")
		wj.JS_FreeValue(ctx, n)
		if !ok { return wj.EXCEPTION }
		t := wj.JS_GetPropertyStr(ctx, opt, "type")
		if wj.is_exception(t) { return t }
		if !wj.is_undefined(t) {
			type, ok = worker_type(ctx, t)
			wj.JS_FreeValue(ctx, t)
			if !ok { return wj.EXCEPTION }
		}
	}
	w: api_decl.Worker
	st: abi.Api_Error
	bp: [^]u8
	bn: uint
	if web_blob_url_bytes(ctx, url.ptr, url.len, &bp, &bn) {
		// a blob: URL of this realm: its Blob's bytes are the script
		st = jsb.host(&w, api_decl.Worker_createScriptBytes, wj.wr_Worker_createScriptBytes, str_view(url), str_view(name), type, abi.Bytes(bp != nil ? bp[:bn] : nil))
	} else {
		st = jsb.host(&w, api_decl.Worker_createScript, wj.wr_Worker_createScript, str_view(url), str_view(name), type)
	}
	#partial switch st {
	case .None:
	case .Syntax, .Not_Supported: return wj.wj_throw_status(ctx, i32(st), "Worker")
	case: return wj.wj_throw_dom(ctx, "SecurityError", "Failed to construct 'Worker': the browser refused to start the worker (the console says why).")
	}
	obj := wj.wj_wrap_owned(ctx, u64(w), jsb.iface_of(api_decl.Worker), new_target)
	if !wj.is_exception(obj) { web_keep_worker(ctx, obj) }
	return obj
}

@(export, link_name = "wjr_Worker_postMessage")
wjr_Worker_postMessage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	w, ok := jsb.this(ctx, this_val, api_decl.Worker)
	if !ok { return wj.EXCEPTION }
	m, serialized := serialize_message(ctx, argc, argv)
	if !serialized { return wj.EXCEPTION }
	defer message_free(m)
	st := len(m.ends) > 0 \
		? jsb.host(&nothing, api_decl.Worker_postSerializedPorts, wj.wr_Worker_postSerializedPorts, w, abi.Bytes(m.bytes), m.ends) \
		: jsb.host(&nothing, api_decl.Worker_postSerialized, wj.wr_Worker_postSerialized, w, abi.Bytes(m.bytes))
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "Worker.postMessage") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Worker_terminate")
wjr_Worker_terminate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	w, ok := jsb.this(ctx, this_val, api_decl.Worker)
	if !ok { return wj.EXCEPTION }
	jsb.host(&nothing, api_decl.Worker_terminate, wj.wr_Worker_terminate, w)
	let_go(ctx, u64(w))
	return wj.UNDEFINED
}

// ---- the worker's side ----

@(export, link_name = "wjr_DedicatedWorkerGlobalScope_postMessage")
wjr_DedicatedWorkerGlobalScope_postMessage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	m, serialized := serialize_message(ctx, argc, argv)
	if !serialized { return wj.EXCEPTION }
	defer message_free(m)
	st := len(m.ends) > 0 \
		? jsb.host(&nothing, api_decl.DedicatedWorkerGlobalScope_postSerializedPorts, wj.wr_DedicatedWorkerGlobalScope_postSerializedPorts, abi.Bytes(m.bytes), m.ends) \
		: jsb.host(&nothing, api_decl.DedicatedWorkerGlobalScope_postSerialized, wj.wr_DedicatedWorkerGlobalScope_postSerialized, abi.Bytes(m.bytes))
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "postMessage") }
	return wj.UNDEFINED
}

// One script of importScripts: its final URL and its source, each NUL-terminated (JS_Eval2 wants both).
@(private = "file")
Script :: struct { url: []u8, source: []u8 }

// importScripts(...urls): every script fetched (synchronously, in order), then run in order; a failure throws
// NetworkError and runs nothing more.
@(export, link_name = "wjr_WorkerGlobalScope_importScripts")
wjr_WorkerGlobalScope_importScripts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	is_module: bool
	jsb.host(&is_module, api_decl.WorkerGlobalScope_isModule, wj.wr_WorkerGlobalScope_isModule)
	if is_module { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'importScripts' on 'WorkerGlobalScope': Module scripts don't support importScripts().") }
	if argc == 0 { return wj.UNDEFINED }
	scripts := make([dynamic]Script, 0, argc)
	defer {
		for s in scripts { delete(s.url); delete(s.source) }
		delete(scripts)
	}
	for i in 0 ..< argc {
		u: wj.Str
		if !wj.wj_to_str(ctx, argv[i], &u, wj.STR_USV, "") { return wj.EXCEPTION }
		// the browser resolves it, fetches it and writes the final URL first, a NUL, then the source
		text: string
		st := jsb.host(&text, api_decl.WorkerGlobalScope_importScript, wj.wr_WorkerGlobalScope_importScript, str_view(u))
		wj.wj_str_free(ctx, &u)
		if st != .None { return wj.wj_throw_status(ctx, i32(st), "importScripts") }
		url_part, source_part := "", text
		for c, k in transmute([]u8)text {
			if c == 0 { url_part, source_part = text[:k], text[k + 1:]; break }
		}
		s := Script{make([]u8, len(url_part) + 1), make([]u8, len(source_part) + 1)}
		if s.url == nil || s.source == nil { delete(s.url); delete(s.source); return wj.JS_ThrowOutOfMemory(ctx) }
		copy(s.url, url_part)
		copy(s.source, source_part)
		append(&scripts, s)
	}
	for s in scripts {
		opt := wj.Eval_Options{version = wj.EVAL_OPTIONS_VERSION, eval_flags = wj.EVAL_TYPE_GLOBAL, filename = cstring(raw_data(s.url)), line_num = 1}
		r := wj.JS_Eval2(ctx, raw_data(s.source), uint(len(s.source) - 1), &opt)
		if wj.is_exception(r) { return r }   // rethrown to the caller of importScripts
		wj.JS_FreeValue(ctx, r)
	}
	return wj.UNDEFINED
}
