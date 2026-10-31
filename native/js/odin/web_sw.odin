// web_sw.odin: service workers for JavaScript (module serviceworker, src/page/service_worker.odin). Ported from
// native/js/runtime/web_sw.c: same wjr_* symbols and exports (wj_sw_container_event, wj_sw_event).
//
// Both realms: ServiceWorkerRegistration (one object per registration id per realm, kept for the realm's life) and
// ServiceWorker (one per version id), their state read from the browser (ServiceWorkerRegistration_info,
// ServiceWorker_info: in a service worker, the copy the browser sent it). When the browser says a registration changed
// (wj_sw_container_event 2 in a page, a registration event in a service worker), the objects compare what they showed:
// statechange at a ServiceWorker whose state moved, updatefound at a registration with a new installing version.
//
// Page side: navigator.serviceWorker (ServiceWorkerContainer: register, ready, getRegistration(s), controller, message /
// controllerchange events), registration.update / unregister / navigationPreload.
//
// Worker side, in the realm of a version's worker (its global a ServiceWorkerGlobalScope): skipWaiting(), clients
// (matchAll / get / openWindow / claim, WindowClient.navigate / focus: requests the browser answers with an event),
// registration, serviceWorker; the browser's events come through wj_sw_event and are fired as ExtendableEvent /
// InstallEvent, FetchEvent (preloadResponse: the navigation preload's response), ExtendableMessageEvent; their outcome
// (waitUntil's promises, respondWith's Response read whole) goes back with ServiceWorkerGlobalScope_reply.
//
// Every call into the browser is a declaration of api_decl/serviceworker.odin through jsb.host.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") none: abi.Nothing

// What the browser says in SwEvent_next (kind).
@(private = "file") Sw_Event :: enum i32 { None, Install, Activate, Fetch, Message, Answer, Registration, Preload }
// What the worker replies (ServiceWorkerGlobalScope_reply's kind).
@(private = "file") Reply :: enum i32 { None, Install_Done, Activate_Done, Respond, Fall_Back, Fail, Skip_Waiting, Claim, Post_Client, Request = 10, Preload = 11 }
// The requests a worker makes of the browser, answered by an event.
@(private = "file") Op :: enum i32 { None, Match_All, Get, Open_Window, Navigate, Focus, Update, Unregister }

@(private = "file")
in_sw :: proc() -> bool {
	id: u64
	jsb.host(&id, api_decl.ServiceWorkerGlobalScope_registration, wj.wr_ServiceWorkerGlobalScope_registration)
	return id != 0
}

@(private = "file")
reply :: proc(kind: Reply, id: u64, code: i64, headers: string = "", text: string = "", body: []u8 = nil) {
	jsb.host(&none, api_decl.ServiceWorkerGlobalScope_reply, wj.wr_ServiceWorkerGlobalScope_reply, i32(kind), id, code, headers, text, abi.Bytes(body))
}

// Promise.all(list) / Promise.resolve(v) of the realm's Promise.
@(private = "file")
promise_call :: proc "contextless" (ctx: ^wj.Context, method: cstring, v: wj.JSValue) -> wj.JSValue {
	promise := global_prop(ctx, "Promise")
	fn := wj.JS_GetPropertyStr(ctx, promise, method)
	arg := v
	r := wj.JS_Call(ctx, fn, promise, 1, &arg)
	wj.free_values(ctx, fn, promise)
	return r
}

// A decimal number at the start of `s` (strtoull), 0 when there is none.
@(private = "file")
number :: proc "contextless" (s: string) -> (v: u64) {
	i := 0
	for i < len(s) && (s[i] == ' ' || (s[i] >= '\t' && s[i] <= '\r')) { i += 1 }
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + u64(s[i] - '0')
		i += 1
	}
	return
}

// The id as the decimal string JavaScript sees.
@(private = "file")
id_text :: proc "contextless" (id: u64, buf: ^[24]u8) -> string {
	n := wj.snprintf(&buf[0], len(buf), "%llu", id)
	return string(buf[:max(n, 0)])
}

// ---- the browser's view of registrations and versions ----

// A registration's fields (strings point into the scratch buffer: read them before the next host call).
@(private = "file")
Reg_Info :: struct {
	scope, update_via_cache:           string,
	installing, waiting, active:       u64,
	preload_enabled:                   string,
	preload_header:                    string,
}

// The registration `id` as the browser describes it; false when it is gone.
@(private = "file")
reg_info :: proc(id: u64) -> (info: Reg_Info, ok: bool) {
	text: string
	jsb.host(&text, api_decl.ServiceWorkerRegistration_info, wj.wr_ServiceWorkerRegistration_info, id)
	if len(text) == 0 { return {}, false }
	fields: [7]string
	rest := text
	for i in 0 ..< 7 {
		line := rest
		cut := false
		for c, k in transmute([]u8)rest { if c == '\n' { line = rest[:k]; rest = rest[k + 1:]; cut = true; break } }
		fields[i] = line
		if !cut { rest = ""; for j in i + 1 ..< 7 { fields[j] = "" }; break }
	}
	return {fields[0], fields[1], number(fields[2]), number(fields[3]), number(fields[4]), fields[5], fields[6]}, true
}

// A version's state: at most 15 bytes.
@(private = "file")
Version_State :: struct {
	bytes: [16]u8,
	n:     u8,
}

@(private = "file")
state_text :: proc "contextless" (s: ^Version_State) -> string { return string(s.bytes[:s.n]) }

@(private = "file")
set_state :: proc "contextless" (s: ^Version_State, text: string) {
	s.n = u8(min(len(text), 15))
	copy(s.bytes[:s.n], text)
}

// A version's state, its script URL as a string value ("redundant" and "" when unknown).
@(private = "file")
version_info :: proc(ctx: ^wj.Context, vid: u64) -> (state: Version_State, url: wj.JSValue) {
	text: string
	jsb.host(&text, api_decl.ServiceWorker_info, wj.wr_ServiceWorker_info, vid)
	if len(text) == 0 {
		set_state(&state, "redundant")
		return state, wj.new_string(ctx, "")
	}
	nl := -1
	for c, k in transmute([]u8)text { if c == '\n' { nl = k; break } }
	set_state(&state, nl >= 0 ? text[:nl] : text)
	return state, nl >= 0 ? wj.new_string_len(ctx, text[nl + 1:]) : wj.new_string(ctx, "")
}

// ---- objects per registration and per version ----

@(private = "file") Reg_Impl :: struct { id: u64 }
@(private = "file") Sw_Impl :: struct { id: u64 }
@(private = "file") Preload_Impl :: struct { reg: u64 }

@(private = "file") Registered :: struct { id: u64, obj: wj.JSValue, installing: u64 }
@(private = "file") Version :: struct { id: u64, obj: wj.JSValue, state: Version_State }
@(private = "file") regs: [dynamic]Registered
@(private = "file") sws: [dynamic]Version

@(private = "file")
registration_of :: proc(ctx: ^wj.Context, id: u64) -> wj.JSValue {
	if id == 0 { return wj.UNDEFINED }
	for r in regs { if r.id == id { return wj.JS_DupValue(ctx, r.obj) } }
	r := new(Reg_Impl)
	if r == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	r.id = id
	obj := wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("ServiceWorkerRegistration"), wj.UNDEFINED)
	if wj.is_exception(obj) { free(r); return obj }
	wj.web_set_impl(obj, r, impl_free(Reg_Impl), nil)
	info, ok := reg_info(id)
	if append(&regs, Registered{id = id, obj = wj.JS_DupValue(ctx, obj), installing = ok ? info.installing : 0}) != 1 { return obj }
	return obj
}

// The free function of an impl allocated with new(T).
@(private = "file")
impl_free :: proc($T: typeid) -> wj.Impl_Free {
	return proc "c" (p: rawptr) {
		context = wj.heap_context()
		free((^T)(p))
	}
}

@(private = "file")
sw_object_of :: proc(ctx: ^wj.Context, vid: u64) -> wj.JSValue {
	if vid == 0 { return wj.NULL }
	for v in sws { if v.id == vid { return wj.JS_DupValue(ctx, v.obj) } }
	w := new(Sw_Impl)
	if w == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	w.id = vid
	obj := wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("ServiceWorker"), wj.UNDEFINED)
	if wj.is_exception(obj) { free(w); return obj }
	wj.web_set_impl(obj, w, impl_free(Sw_Impl), nil)
	state, url := version_info(ctx, vid)
	wj.JS_FreeValue(ctx, url)
	if append(&sws, Version{id = vid, obj = wj.JS_DupValue(ctx, obj), state = state}) != 1 { return obj }
	return obj
}

// The browser says a registration changed: statechange where a version's state moved, updatefound where a new version
// installs (Service Workers "update worker state", "update registration state").
@(private = "file")
refresh :: proc(ctx: ^wj.Context) {
	for &r in regs {
		inst: u64
		if info, ok := reg_info(r.id); ok { inst = info.installing }
		if inst != r.installing {
			r.installing = inst
			if inst != 0 {
				o := wj.JS_DupValue(ctx, r.obj)
				wj.web_fire_simple(ctx, o, "updatefound")
				wj.JS_FreeValue(ctx, o)
			}
		}
	}
	for &v in sws {
		state, url := version_info(ctx, v.id)
		wj.JS_FreeValue(ctx, url)
		if state_text(&state) == state_text(&v.state) { continue }
		v.state = state
		o := wj.JS_DupValue(ctx, v.obj)
		wj.web_fire_simple(ctx, o, "statechange")
		wj.JS_FreeValue(ctx, o)
	}
}

@(private = "file")
reg_this :: #force_inline proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> ^Reg_Impl {
	return (^Reg_Impl)(wj.this_impl(ctx, v, ifc("ServiceWorkerRegistration")))
}

@(export, link_name = "wjr_ServiceWorkerRegistration_get_scope")
wjr_ServiceWorkerRegistration_get_scope :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reg_this(ctx, t)
	if r == nil { return wj.EXCEPTION }
	if info, ok := reg_info(r.id); ok { return wj.new_string_len(ctx, info.scope) }
	// gone: the scope it had (a service worker reads its own)
	scope: string
	jsb.host(&scope, api_decl.ServiceWorkerGlobalScope_scope, wj.wr_ServiceWorkerGlobalScope_scope)
	return wj.new_string_len(ctx, scope)
}

@(export, link_name = "wjr_ServiceWorkerRegistration_get_updateViaCache")
wjr_ServiceWorkerRegistration_get_updateViaCache :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reg_this(ctx, t)
	if r == nil { return wj.EXCEPTION }
	info, ok := reg_info(r.id)
	return wj.new_string_len(ctx, ok && info.update_via_cache != "" ? info.update_via_cache : "imports")
}

@(private = "file")
version_in :: proc(ctx: ^wj.Context, t: wj.JSValue, which: int) -> wj.JSValue {
	r := reg_this(ctx, t)
	if r == nil { return wj.EXCEPTION }
	vid: u64
	if info, ok := reg_info(r.id); ok {
		switch which {
		case 0: vid = info.installing
		case 1: vid = info.waiting
		case 2: vid = info.active
		}
	}
	return sw_object_of(ctx, vid)
}

@(export, link_name = "wjr_ServiceWorkerRegistration_get_installing")
wjr_ServiceWorkerRegistration_get_installing :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return version_in(ctx, t, 0)
}
@(export, link_name = "wjr_ServiceWorkerRegistration_get_waiting")
wjr_ServiceWorkerRegistration_get_waiting :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return version_in(ctx, t, 1)
}
@(export, link_name = "wjr_ServiceWorkerRegistration_get_active")
wjr_ServiceWorkerRegistration_get_active :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return version_in(ctx, t, 2)
}

// ---- requests a service worker makes of the browser (answered by an event) ----

@(private = "file") Request :: struct { id: u64, op: Op, promise: Prom }
@(private = "file") reqs: [dynamic]Request
@(private = "file") next_req: u64

// Asks the browser (reply Request, code = the op) and returns the promise its answer settles.
@(private = "file")
request :: proc(ctx: ^wj.Context, op: Op, text: string, extra: string) -> wj.JSValue {
	req := Request{op = op, promise = PROM_NONE}
	prom_new(ctx, &req.promise)
	if wj.is_exception(req.promise.p) { return wj.web_promise_reject_pending(ctx) }
	next_req += 1
	req.id = next_req
	p := wj.JS_DupValue(ctx, req.promise.p)
	if append(&reqs, req) != 1 {
		prom_clear(ctx, &req.promise)
		wj.JS_FreeValue(ctx, p)
		wj.JS_ThrowOutOfMemory(ctx)
		return wj.web_promise_reject_pending(ctx)
	}
	reply(.Request, next_req, i64(op), extra, text)
	return p
}

// A browser promise of a registration id -> the registration (rejections: their error).
@(private = "file")
settle_reg :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	context = wj.heap_context()
	if state != 1 {
		reject^ = true
		msg := wj.wj_host_promise_text(ctx, host)
		defer wj.JS_FreeValue(ctx, msg)
		c, s := to_text(ctx, msg)
		defer if c != nil { wj.JS_FreeCString(ctx, c) }
		return wj.web_error_value(ctx, i32(value), raw_data(s), uint(len(s)))
	}
	return registration_of(ctx, u64(value))
}

@(export, link_name = "wjr_ServiceWorkerRegistration_update")
wjr_ServiceWorkerRegistration_update :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reg_this(ctx, t)
	if r == nil { return wj.web_promise_reject_pending(ctx) }
	if in_sw() { return request(ctx, .Update, "", "") }
	host: api_decl.Promise
	if st := jsb.host(&host, api_decl.ServiceWorkerRegistration_updateId, wj.wr_ServiceWorkerRegistration_updateId, r.id); st != .None {
		wj.wj_throw_status(ctx, i32(st), "ServiceWorkerRegistration.update")
		return wj.web_promise_reject_pending(ctx)
	}
	return wj.wj_promise_from_host(ctx, u64(host), wj.HOST_NUMBER, settle_reg, wj.UNDEFINED)
}

@(export, link_name = "wjr_ServiceWorkerRegistration_unregister")
wjr_ServiceWorkerRegistration_unregister :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reg_this(ctx, t)
	if r == nil { return wj.web_promise_reject_pending(ctx) }
	if in_sw() { return request(ctx, .Unregister, "", "") }
	done: bool
	jsb.host(&done, api_decl.ServiceWorkerRegistration_unregisterId, wj.wr_ServiceWorkerRegistration_unregisterId, r.id)
	return wj.web_promise_take(ctx, wj.new_bool(done))
}

// ---- navigation preload (NavigationPreloadManager) ----

@(export, link_name = "wjr_ServiceWorkerRegistration_get_navigationPreload")
wjr_ServiceWorkerRegistration_get_navigationPreload :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reg_this(ctx, t)
	if r == nil { return wj.EXCEPTION }
	p := new(Preload_Impl)
	if p == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	p.reg = r.id
	return wj.wj_new_object(ctx, ifc("NavigationPreloadManager"), p, impl_free(Preload_Impl))   // [SameObject]: kept by the binding
}

@(private = "file")
preload_op :: proc(ctx: ^wj.Context, t: wj.JSValue, op: i32, header_v: wj.JSValue) -> wj.JSValue {
	p := (^Preload_Impl)(wj.this_impl(ctx, t, ifc("NavigationPreloadManager")))
	if p == nil { return wj.web_promise_reject_pending(ctx) }
	h: wj.Str
	defer wj.wj_str_free(ctx, &h)
	if op == 3 && !wj.web_to_bytestring(ctx, header_v, &h) { return wj.web_promise_reject_pending(ctx) }
	text: string
	if st := jsb.host(&text, api_decl.ServiceWorkerRegistration_preload, wj.wr_ServiceWorkerRegistration_preload, p.reg, op, str_view(h)); st != .None {
		wj.wj_throw_status(ctx, i32(st), "NavigationPreloadManager")
		return wj.web_promise_reject_pending(ctx)
	}
	if op != 0 { return wj.web_promise_take(ctx, wj.UNDEFINED) }
	// {enabled, headerValue}
	state := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, state, "enabled", wj.new_bool(len(text) > 0 && text[0] == '1'))
	nl := -1
	for c, k in transmute([]u8)text { if c == '\n' { nl = k; break } }
	wj.JS_SetPropertyStr(ctx, state, "headerValue", nl >= 0 ? wj.new_string_len(ctx, text[nl + 1:]) : wj.new_string(ctx, "true"))
	return wj.web_promise_take(ctx, state)
}

@(export, link_name = "wjr_NavigationPreloadManager_enable")
wjr_NavigationPreloadManager_enable :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return preload_op(ctx, t, 1, wj.UNDEFINED)
}
@(export, link_name = "wjr_NavigationPreloadManager_disable")
wjr_NavigationPreloadManager_disable :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return preload_op(ctx, t, 2, wj.UNDEFINED)
}
@(export, link_name = "wjr_NavigationPreloadManager_getState")
wjr_NavigationPreloadManager_getState :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return preload_op(ctx, t, 0, wj.UNDEFINED)
}
@(export, link_name = "wjr_NavigationPreloadManager_setHeaderValue")
wjr_NavigationPreloadManager_setHeaderValue :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 {
		wj.wj_throw_arity(ctx, "NavigationPreloadManager.setHeaderValue", 1, argc)
		return wj.web_promise_reject_pending(ctx)
	}
	return preload_op(ctx, t, 3, argv[0])
}

// ---- ServiceWorker ----

@(private = "file")
sw_this :: #force_inline proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> ^Sw_Impl {
	return (^Sw_Impl)(wj.this_impl(ctx, v, ifc("ServiceWorker")))
}

@(export, link_name = "wjr_ServiceWorker_get_scriptURL")
wjr_ServiceWorker_get_scriptURL :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := sw_this(ctx, t)
	if w == nil { return wj.EXCEPTION }
	_, url := version_info(ctx, w.id)
	return url
}

@(export, link_name = "wjr_ServiceWorker_get_state")
wjr_ServiceWorker_get_state :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := sw_this(ctx, t)
	if w == nil { return wj.EXCEPTION }
	// the state the object showed last (statechange fires when it moves: refresh)
	for &v in sws { if v.id == w.id { return wj.new_string_len(ctx, state_text(&v.state)) } }
	state, url := version_info(ctx, w.id)
	wj.JS_FreeValue(ctx, url)
	return wj.new_string_len(ctx, state_text(&state))
}

@(export, link_name = "wjr_ServiceWorker_postMessage")
wjr_ServiceWorker_postMessage :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := sw_this(ctx, t)
	if w == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "ServiceWorker.postMessage", 1, argc) }
	n: uint
	data := web_clone_serialize(ctx, argv[0], &n)
	if data == nil { return wj.EXCEPTION }
	defer web_clone_free(ctx, data)
	if st := jsb.host(&none, api_decl.ServiceWorker_postToWorker, wj.wr_ServiceWorker_postToWorker, w.id, abi.Bytes(data[:n])); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "ServiceWorker.postMessage")
	}
	return wj.UNDEFINED
}

// ---- ServiceWorkerContainer (page side) ----

@(private = "file") Container :: struct { ready: wj.JSValue }

@(private = "file")
container_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^Container)(p).ready)
	wj.libc_free(p)
}
@(private = "file")
container_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Container)(p).ready, mark_func) }

@(private = "file")
make_container :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	c := (^Container)(wj.libc_calloc(1, size_of(Container)))
	if c == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	c.ready = wj.UNDEFINED
	obj := wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("ServiceWorkerContainer"), wj.UNDEFINED)
	if wj.is_exception(obj) { wj.libc_free(c); return obj }
	wj.web_set_impl(obj, c, container_free, container_mark)
	return obj
}

@(export, link_name = "wjr_Navigator_get_serviceWorker")
wjr_Navigator_get_serviceWorker :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("Navigator")) == nil { return wj.EXCEPTION }
	return wj.web_singleton(ctx, wj.SINGLE_SERVICE_WORKER, make_container)
}

// A worker's: it sees its document's controller (src/page/service_worker.odin sw_client_init).
@(export, link_name = "wjr_WorkerNavigator_get_serviceWorker")
wjr_WorkerNavigator_get_serviceWorker :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("WorkerNavigator")) == nil { return wj.EXCEPTION }
	return wj.web_singleton(ctx, wj.SINGLE_SERVICE_WORKER, make_container)
}

@(export, link_name = "wjr_ServiceWorkerContainer_register")
wjr_ServiceWorkerContainer_register :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("ServiceWorkerContainer")) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 {
		wj.wj_throw_arity(ctx, "ServiceWorkerContainer.register", 1, argc)
		return wj.web_promise_reject_pending(ctx)
	}
	script, scope: wj.Str
	via := wj.Str{wj.raw_bytes("imports"), 7, false}
	if !wj.web_to_usv(ctx, argv[0], &script) { return wj.web_promise_reject_pending(ctx) }
	defer wj.wj_str_free(ctx, &script)
	opt := wj.arg(argc, argv, 1)
	v: wj.JSValue
	has_scope, module := false, false
	if !wj.web_dict_check(ctx, opt, "RegistrationOptions") || !wj.web_dict_get(ctx, opt, "scope", &v) { return wj.web_promise_reject_pending(ctx) }
	if !wj.is_undefined(v) {
		has_scope = wj.web_to_usv(ctx, v, &scope)
		wj.JS_FreeValue(ctx, v)
		if !has_scope { return wj.web_promise_reject_pending(ctx) }
	}
	defer if has_scope { wj.wj_str_free(ctx, &scope) }
	if !wj.web_dict_get(ctx, opt, "type", &v) { return wj.web_promise_reject_pending(ctx) }
	if !wj.is_undefined(v) {
		c, ty := to_text(ctx, v)
		known := c != nil && (ty == "classic" || ty == "module")
		module = c != nil && ty == "module"
		if c != nil { wj.JS_FreeCString(ctx, c) }
		wj.JS_FreeValue(ctx, v)
		if !known {
			if !wj.JS_HasException(ctx) { wj.JS_ThrowTypeError(ctx, "Failed to execute 'register': The provided value is not a valid enum value of type WorkerType.") }
			return wj.web_promise_reject_pending(ctx)
		}
	}
	via_owned := false
	defer if via_owned { wj.wj_str_free(ctx, &via) }
	if wj.web_dict_get(ctx, opt, "updateViaCache", &v) && !wj.is_undefined(v) {
		via = {}
		wj.wj_to_str(ctx, v, &via, 0, nil)
		via_owned = true
		wj.JS_FreeValue(ctx, v)
		if text := str_view(via); text != "imports" && text != "all" && text != "none" {
			wj.JS_ThrowTypeError(ctx, "Failed to execute 'register': The provided value is not a valid enum value of type ServiceWorkerUpdateViaCache.")
			return wj.web_promise_reject_pending(ctx)
		}
	}
	host: api_decl.Promise
	if st := jsb.host(&host, api_decl.ServiceWorker_register, wj.wr_ServiceWorker_register, str_view(script), has_scope ? Maybe(string)(str_view(scope)) : nil, str_view(via), module); st != .None {
		wj.wj_throw_status(ctx, i32(st), "ServiceWorkerContainer.register")
		return wj.web_promise_reject_pending(ctx)
	}
	return wj.wj_promise_from_host(ctx, u64(host), wj.HOST_NUMBER, settle_reg, wj.UNDEFINED)
}

@(export, link_name = "wjr_ServiceWorkerContainer_get_ready")
wjr_ServiceWorkerContainer_get_ready :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	o := wj.wj_this(ctx, t, ifc("ServiceWorkerContainer"))
	if o == nil { return wj.EXCEPTION }
	c := (^Container)(o.impl)
	if c == nil { return wj.UNDEFINED }
	if wj.is_undefined(c.ready) {
		host: api_decl.Promise
		jsb.host(&host, api_decl.ServiceWorker_ready, wj.wr_ServiceWorker_ready)
		c.ready = wj.wj_promise_from_host(ctx, u64(host), wj.HOST_NUMBER, settle_reg, wj.UNDEFINED)
	}
	return wj.JS_DupValue(ctx, c.ready)
}

@(export, link_name = "wjr_ServiceWorkerContainer_get_controller")
wjr_ServiceWorkerContainer_get_controller :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("ServiceWorkerContainer")) == nil { return wj.EXCEPTION }
	vid: u64
	jsb.host(&vid, api_decl.ServiceWorker_controller, wj.wr_ServiceWorker_controller)
	return sw_object_of(ctx, vid)
}

@(export, link_name = "wjr_ServiceWorkerContainer_getRegistration")
wjr_ServiceWorkerContainer_getRegistration :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("ServiceWorkerContainer")) == nil { return wj.web_promise_reject_pending(ctx) }
	u := wj.Str{wj.empty_ptr(), 0, false}
	defer wj.wj_str_free(ctx, &u)
	if argc > 0 && !wj.is_undefined(argv[0]) && !wj.web_to_usv(ctx, argv[0], &u) { return wj.web_promise_reject_pending(ctx) }
	id: u64
	jsb.host(&id, api_decl.ServiceWorker_getRegistration, wj.wr_ServiceWorker_getRegistration, str_view(u))
	r := registration_of(ctx, id)
	return wj.is_exception(r) ? wj.web_promise_reject_pending(ctx) : wj.web_promise_take(ctx, r)
}

@(export, link_name = "wjr_ServiceWorkerContainer_getRegistrations")
wjr_ServiceWorkerContainer_getRegistrations :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("ServiceWorkerContainer")) == nil { return wj.web_promise_reject_pending(ctx) }
	listing: string
	jsb.host(&listing, api_decl.ServiceWorker_registrationIds, wj.wr_ServiceWorker_registrationIds)
	ids := clone_string(listing)
	defer if ids != "" { delete(ids, wj.libc_allocator()) }
	arr := wj.JS_NewArray(ctx)
	k: u32
	rest := ids
	for len(rest) > 0 {
		line := rest
		nl := -1
		for c, i in transmute([]u8)rest { if c == '\n' { nl = i; break } }
		if nl >= 0 { line = rest[:nl]; rest = rest[nl + 1:] } else { rest = "" }
		if id := number(line); id != 0 {
			wj.JS_SetPropertyUint32(ctx, arr, k, registration_of(ctx, id))
			k += 1
		}
	}
	wj.web_freeze(ctx, arr)
	return wj.web_promise_take(ctx, arr)
}

@(export, link_name = "wjr_ServiceWorkerContainer_startMessages")
wjr_ServiceWorkerContainer_startMessages :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, t, ifc("ServiceWorkerContainer")) != nil ? wj.UNDEFINED : wj.EXCEPTION
}

// A copy on the libc heap ("" for an empty string).
@(private = "file")
clone_string :: proc(s: string) -> string {
	if len(s) == 0 { return "" }
	b := make([]u8, len(s), wj.libc_allocator())
	copy(b, s)
	return string(b)
}

// The browser: an event of navigator.serviceWorker (0 controllerchange, 1 the messages waiting from service workers, 2 a
// registration of the origin changed).
@(export, link_name = "wj_sw_container_event")
wj_sw_container_event :: proc "c" (kind: u32) {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if kind == 2 { refresh(ctx); return }
	c := wj.web_singleton(ctx, wj.SINGLE_SERVICE_WORKER, make_container)
	if wj.is_exception(c) { wj.wj_report_pending(ctx); return }
	defer wj.JS_FreeValue(ctx, c)
	if kind == 0 {
		wj.web_fire_simple(ctx, c, "controllerchange")
		return
	}
	for {
		message: abi.Bytes
		jsb.host(&message, api_decl.ServiceWorker_takeMessage, wj.wr_ServiceWorker_takeMessage)
		if len(message) < 8 { break }
		packed := ([]u8)(message)
		vid := wj.read_u64(raw_data(packed))
		value := web_clone_deserialize(ctx, raw_data(packed[8:]), uint(len(packed) - 8))
		ev: wj.JSValue
		if wj.is_exception(value) {
			wj.drop_exception(ctx)
			ev = wj.web_event_new(ctx, ifc("MessageEvent"), "messageerror", false, false)
		} else {
			origin := global_prop(ctx, "origin")
			oc: cstring
			if wj.is_string(origin) { oc = wj.JS_ToCString(ctx, origin) }
			src := sw_object_of(ctx, vid)
			ev = web_message_event(ctx, value, oc != nil ? oc : "", wj.is_exception(src) ? wj.NULL : src)
			wj.JS_FreeValue(ctx, src)
			if oc != nil { wj.JS_FreeCString(ctx, oc) }
			wj.free_values(ctx, origin, value)
		}
		if wj.is_exception(ev) { wj.wj_report_pending(ctx); break }
		wj.web_event_fire(ctx, c, ev)
		wj.JS_FreeValue(ctx, ev)
	}
}

// ---- clients (worker side) ----

// A client as the browser describes it: id TAB url TAB type TAB frameType TAB visibility TAB focused.
@(private = "file")
Client :: struct {
	id:                                   u64,
	url, type, frame, visibility:         wj.JSValue,
	focused:                              bool,
}

@(private = "file")
client_free :: proc "c" (p: rawptr) {
	c := (^Client)(p)
	rt := wj.web_rt()
	for v in ([?]wj.JSValue{c.url, c.type, c.frame, c.visibility}) { wj.JS_FreeValueRT(rt, v) }
	wj.libc_free(p)
}
@(private = "file")
client_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	c := (^Client)(p)
	for v in ([?]wj.JSValue{c.url, c.type, c.frame, c.visibility}) { wj.wj_mark(rt, v, mark_func) }
}

@(private = "file")
client_from_line :: proc(ctx: ^wj.Context, line: string) -> wj.JSValue {
	f := [6]string{"", "", "window", "top-level", "visible", "0"}
	rest := line
	for i in 0 ..< 6 {
		tab := -1
		for c, k in transmute([]u8)rest { if c == '\t' { tab = k; break } }
		if tab < 0 { f[i] = rest; break }
		f[i] = rest[:tab]
		rest = rest[tab + 1:]
	}
	c := (^Client)(wj.libc_calloc(1, size_of(Client)))
	if c == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	c.id = number(f[0])
	c.url = wj.new_string_len(ctx, f[1])
	c.type = wj.new_string_len(ctx, f[2])
	c.frame = wj.new_string_len(ctx, f[3])
	c.visibility = wj.new_string_len(ctx, f[4])
	c.focused = f[5] == "1"
	// a window is a WindowClient; a worker or a shared worker a plain Client
	obj := wj.wj_new_object(ctx, f[2] == "window" ? ifc("WindowClient") : ifc("Client"), nil, nil)
	if wj.is_exception(obj) { client_free(c); return obj }
	wj.web_set_impl(obj, c, client_free, client_mark)
	return obj
}

@(private = "file")
client_this :: #force_inline proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> ^Client {
	return (^Client)(wj.this_impl(ctx, v, ifc("Client")))
}

@(export, link_name = "wjr_Client_get_url")       wjr_Client_get_url       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { c := client_this(ctx, t); return c != nil ? wj.JS_DupValue(ctx, c.url) : wj.EXCEPTION }
@(export, link_name = "wjr_Client_get_frameType") wjr_Client_get_frameType :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { c := client_this(ctx, t); return c != nil ? wj.JS_DupValue(ctx, c.frame) : wj.EXCEPTION }
@(export, link_name = "wjr_Client_get_type")      wjr_Client_get_type      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { c := client_this(ctx, t); return c != nil ? wj.JS_DupValue(ctx, c.type) : wj.EXCEPTION }

@(export, link_name = "wjr_Client_get_id")
wjr_Client_get_id :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	c := client_this(ctx, t)
	if c == nil { return wj.EXCEPTION }
	buf: [24]u8
	return wj.new_string_len(ctx, id_text(c.id, &buf))
}

@(export, link_name = "wjr_Client_postMessage")
wjr_Client_postMessage :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	c := client_this(ctx, t)
	if c == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Client.postMessage", 1, argc) }
	n: uint
	data := web_clone_serialize(ctx, argv[0], &n)
	if data == nil { return wj.EXCEPTION }
	reply(.Post_Client, 0, i64(c.id), body = data[:n])
	web_clone_free(ctx, data)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_WindowClient_get_visibilityState")
wjr_WindowClient_get_visibilityState :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	c := (^Client)(wj.this_impl(ctx, t, ifc("WindowClient")))
	return c != nil ? wj.JS_DupValue(ctx, c.visibility) : wj.EXCEPTION
}
@(export, link_name = "wjr_WindowClient_get_focused")
wjr_WindowClient_get_focused :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	c := (^Client)(wj.this_impl(ctx, t, ifc("WindowClient")))
	return c != nil ? wj.new_bool(c.focused) : wj.EXCEPTION
}

@(export, link_name = "wjr_WindowClient_focus")
wjr_WindowClient_focus :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	c := (^Client)(wj.this_impl(ctx, t, ifc("WindowClient")))
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	buf: [24]u8
	return request(ctx, .Focus, id_text(c.id, &buf), "")
}

// An URL argument resolved against the service worker's location.
@(private = "file")
url_arg :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wj.Str) -> bool {
	s: wj.Str
	if !wj.web_to_usv(ctx, v, &s) { return false }
	defer wj.wj_str_free(ctx, &s)
	return web_resolve_url(ctx, s.ptr, s.len, out)
}

@(export, link_name = "wjr_WindowClient_navigate")
wjr_WindowClient_navigate :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	c := (^Client)(wj.this_impl(ctx, t, ifc("WindowClient")))
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 {
		wj.wj_throw_arity(ctx, "WindowClient.navigate", 1, argc)
		return wj.web_promise_reject_pending(ctx)
	}
	u: wj.Str
	if !url_arg(ctx, argv[0], &u) { return wj.web_promise_reject_pending(ctx) }
	defer wj.libc_free(rawptr(u.ptr))
	buf: [24]u8
	return request(ctx, .Navigate, str_view(u), id_text(c.id, &buf))
}

@(export, link_name = "wjr_Clients_matchAll")
wjr_Clients_matchAll :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("Clients")) == nil { return wj.web_promise_reject_pending(ctx) }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "ClientQueryOptions") { return wj.web_promise_reject_pending(ctx) }
	v: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "includeUncontrolled", &v) { return wj.web_promise_reject_pending(ctx) }
	unc := wj.JS_ToBool(ctx, v) > 0
	wj.JS_FreeValue(ctx, v)
	type := "window"
	if !wj.web_dict_get(ctx, opt, "type", &v) { return wj.web_promise_reject_pending(ctx) }
	if !wj.is_undefined(v) {
		c, s := to_text(ctx, v)
		wj.JS_FreeValue(ctx, v)
		known := c != nil && (s == "window" || s == "worker" || s == "sharedworker" || s == "all")
		if known { type = s }
		defer if c != nil { wj.JS_FreeCString(ctx, c) }
		if !known {
			if !wj.JS_HasException(ctx) { wj.JS_ThrowTypeError(ctx, "Failed to execute 'matchAll': The provided value is not a valid enum value of type ClientType.") }
			return wj.web_promise_reject_pending(ctx)
		}
		return request(ctx, .Match_All, "", fmt_extra(unc, type))
	}
	return request(ctx, .Match_All, "", fmt_extra(unc, type))
}

// "<0|1>\t<type>": the extra of a matchAll request (on the libc heap; leaks nothing that matters: a few bytes per call is
// the C's snprintf buffer on the stack, so a static one here).
@(private = "file") extra_buffer: [48]u8
@(private = "file")
fmt_extra :: proc "contextless" (unc: bool, type: string) -> string {
	n := wj.snprintf(&extra_buffer[0], len(extra_buffer), "%d\t%.*s", i32(unc ? 1 : 0), i32(len(type)), raw_data(type))
	return string(extra_buffer[:max(n, 0)])
}

@(export, link_name = "wjr_Clients_get")
wjr_Clients_get :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("Clients")) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 {
		wj.wj_throw_arity(ctx, "Clients.get", 1, argc)
		return wj.web_promise_reject_pending(ctx)
	}
	id: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &id, 0, nil) { return wj.web_promise_reject_pending(ctx) }
	defer wj.wj_str_free(ctx, &id)
	return request(ctx, .Get, str_view(id), "")
}

@(export, link_name = "wjr_Clients_claim")
wjr_Clients_claim :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("Clients")) == nil { return wj.web_promise_reject_pending(ctx) }
	reply(.Claim, 0, 0)
	return wj.web_promise_take(ctx, wj.UNDEFINED)
}

@(export, link_name = "wjr_Clients_openWindow")
wjr_Clients_openWindow :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("Clients")) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 {
		wj.wj_throw_arity(ctx, "Clients.openWindow", 1, argc)
		return wj.web_promise_reject_pending(ctx)
	}
	u: wj.Str
	if !url_arg(ctx, argv[0], &u) { return wj.web_promise_reject_pending(ctx) }
	defer wj.libc_free(rawptr(u.ptr))
	return request(ctx, .Open_Window, str_view(u), "")
}

// The browser answered request `id`: ok (text: client lines, or nothing) or rejected (text: "Name: why").
@(private = "file")
answer :: proc(ctx: ^wj.Context, id: u64, ok: bool, text: string) {
	at := -1
	for r, i in reqs { if r.id == id { at = i; break } }
	if at < 0 { return }
	req := reqs[at]
	unordered_remove(&reqs, at)
	prom := req.promise
	defer prom_clear(ctx, &prom)
	if !ok {
		colon := -1
		for c, i in transmute([]u8)text { if c == ':' { colon = i; break } }
		name := "InvalidStateError"
		msg := text
		if colon >= 0 {
			if colon > 0 && colon < 48 { name = text[:colon] }
			msg = text[colon + 1:]
		}
		for len(msg) > 0 && msg[0] == ' ' { msg = msg[1:] }
		name_c := clone_cstring(name)
		msg_c := clone_cstring(msg)
		defer delete(name_c, wj.libc_allocator())
		defer delete(msg_c, wj.libc_allocator())
		v := name == "TypeError" ? wj.web_type_error(ctx, cstring(raw_data(msg_c))) : wj.web_dom_exception(ctx, cstring(raw_data(name_c)), cstring(raw_data(msg_c)))
		prom_reject(ctx, &prom, v)
		wj.JS_FreeValue(ctx, v)
		return
	}
	v: wj.JSValue
	#partial switch req.op {
	case .Match_All:
		v = wj.JS_NewArray(ctx)
		k: u32
		rest := text
		for len(rest) > 0 {
			line := rest
			nl := -1
			for c, i in transmute([]u8)rest { if c == '\n' { nl = i; break } }
			if nl >= 0 { line = rest[:nl]; rest = rest[nl + 1:] } else { rest = "" }
			if len(line) == 0 { continue }
			c := client_from_line(ctx, line)
			if wj.is_exception(c) { wj.drop_exception(ctx) } else { wj.JS_SetPropertyUint32(ctx, v, k, c); k += 1 }
		}
		wj.web_freeze(ctx, v)
	case .Get, .Open_Window, .Navigate, .Focus:
		v = len(text) > 0 ? client_from_line(ctx, text) : (req.op == .Get ? wj.UNDEFINED : wj.NULL)
		if wj.is_exception(v) { wj.drop_exception(ctx); v = wj.NULL }
	case .Update:
		reg: u64
		jsb.host(&reg, api_decl.ServiceWorkerGlobalScope_registration, wj.wr_ServiceWorkerGlobalScope_registration)
		v = registration_of(ctx, reg)
	case .Unregister:
		v = wj.new_bool(len(text) > 0 && text[0] == '1')
	case:
		v = wj.UNDEFINED
	}
	prom_resolve(ctx, &prom, v)
	wj.JS_FreeValue(ctx, v)
}

// A NUL-terminated copy of `s` on the libc heap (an Odin byte slice with the NUL kept after its length).
@(private = "file")
clone_cstring :: proc(s: string) -> []u8 {
	b := make([]u8, len(s) + 1, wj.libc_allocator())
	copy(b, s)
	return b
}

// ---- ExtendableEvent, FetchEvent, ExtendableMessageEvent ----

@(export, link_name = "wjr_ExtendableEvent_constructor")
wjr_ExtendableEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj_event_construct(ctx, nt, argc, argv, ifc("ExtendableEvent"), "ExtendableEvent")
}
@(export, link_name = "wjr_InstallEvent_constructor")
wjr_InstallEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj_event_construct(ctx, nt, argc, argv, ifc("InstallEvent"), "InstallEvent")
}

@(export, link_name = "wjr_FetchEvent_constructor")
wjr_FetchEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	init := wj.arg(argc, argv, 1)
	req := wj.is_object(init) ? wj.JS_GetPropertyStr(ctx, init, "request") : wj.UNDEFINED
	if wj.wj_unwrap(req, ifc("Request")) == nil {
		wj.JS_FreeValue(ctx, req)
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'FetchEvent': required member request is undefined.")
	}
	ev := wj_event_construct(ctx, nt, argc, argv, ifc("FetchEvent"), "FetchEvent")
	if wj.is_exception(ev) { wj.JS_FreeValue(ctx, req); return ev }
	wj.web_extra_set(ctx, ev, "request", req)
	for name in ([?]cstring{"clientId", "resultingClientId", "replacesClientId"}) {
		v := wj.JS_GetPropertyStr(ctx, init, name)
		wj.web_extra_set(ctx, ev, name, wj.is_undefined(v) ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, v))
		wj.JS_FreeValue(ctx, v)
	}
	pr := wj.JS_GetPropertyStr(ctx, init, "preloadResponse")
	wj.web_extra_set(ctx, ev, "_preload", wj.is_undefined(pr) ? wj.web_promise_take(ctx, wj.UNDEFINED) : pr)
	return ev
}

@(export, link_name = "wjr_ExtendableMessageEvent_constructor")
wjr_ExtendableMessageEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj_event_construct(ctx, nt, argc, argv, ifc("ExtendableMessageEvent"), "ExtendableMessageEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	for name in ([?]cstring{"data", "origin", "lastEventId", "source", "ports"}) {
		v := wj.is_object(init) ? wj.JS_GetPropertyStr(ctx, init, name) : wj.UNDEFINED
		if !wj.is_undefined(v) { wj.web_extra_set(ctx, ev, name, v) }
	}
	return ev
}

@(private = "file")
extra_or :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, name: cstring, def: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, iface) == nil { wj.JS_FreeValue(ctx, def); return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, t, name)
	if wj.is_undefined(v) { return def }
	wj.JS_FreeValue(ctx, def)
	return v
}

// ExtendableEvent's lifetime promises: how many have not settled ("_pending"), whether one was rejected ("_failed"), and what
// to tell the browser when the last one settles after the dispatch ("_settle": its Sw_Event + 1).
@(private = "file")
extra_int :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring) -> i32 {
	v := wj.web_extra_get(ctx, t, name)
	defer wj.JS_FreeValue(ctx, v)
	x: i32
	if !wj.is_undefined(v) { wj.JS_ToInt32(ctx, &x, v) }
	return x
}

@(private = "file")
lifetime_settled :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, failed: bool) {
	if failed { wj.web_extra_set(ctx, t, "_failed", wj.new_int32(1)) }
	n := extra_int(ctx, t, "_pending") - 1
	wj.web_extra_set(ctx, t, "_pending", wj.new_int32(n))
	settle := extra_int(ctx, t, "_settle")
	if n > 0 || settle == 0 { return }
	wj.web_extra_set(ctx, t, "_settle", wj.new_int32(0))
	lifetime_finish(ctx, t, settle - 1)
}

// install / activate over. (A failed activate still activates: the standard ignores its promises' rejections.)
@(private = "file")
lifetime_finish :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, kind: i32) {
	extend_settled(ctx, kind, kind == i32(Sw_Event.Activate) || extra_int(ctx, t, "_failed") == 0 ? 1 : 0)
}

@(private = "file")
lifetime_ok :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	lifetime_settled(ctx, data[0], false)
	return wj.UNDEFINED
}

@(private = "file")
lifetime_err :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	lifetime_settled(ctx, data[0], true)
	return wj.UNDEFINED
}

// The event lives until `v` settles too.
@(private = "file")
lifetime_add :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> bool {
	p := promise_call(ctx, "resolve", v)
	if wj.is_exception(p) { return false }
	defer wj.JS_FreeValue(ctx, p)
	d := t
	r := wj.web_then(ctx, p, rawptr(lifetime_ok), rawptr(lifetime_err), 1, &d)
	if wj.is_exception(r) { return false }
	wj.JS_FreeValue(ctx, r)
	wj.web_extra_set(ctx, t, "_pending", wj.new_int32(extra_int(ctx, t, "_pending") + 1))
	return true
}

// waitUntil(promise): while the event is dispatched, or while it has promises that have not settled.
@(export, link_name = "wjr_ExtendableEvent_waitUntil")
wjr_ExtendableEvent_waitUntil :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("ExtendableEvent")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "ExtendableEvent.waitUntil", 1, argc) }
	if wj.web_event_host(t) == 0 && extra_int(ctx, t, "_pending") == 0 {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "The event handler is already finished.")
	}
	return lifetime_add(ctx, t, argv[0]) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_InstallEvent_addRoutes")
wjr_InstallEvent_addRoutes :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("InstallEvent")) == nil { return wj.web_promise_reject_pending(ctx) }
	wj.wj_throw_dom(ctx, "NotSupportedError", "static routing (addRoutes) is not supported")
	return wj.web_promise_reject_pending(ctx)
}

@(export, link_name = "wjr_FetchEvent_get_request")           wjr_FetchEvent_get_request           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("FetchEvent"), "request", wj.NULL) }
@(export, link_name = "wjr_FetchEvent_get_clientId")          wjr_FetchEvent_get_clientId          :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("FetchEvent"), "clientId", wj.new_string(ctx, "")) }
@(export, link_name = "wjr_FetchEvent_get_resultingClientId") wjr_FetchEvent_get_resultingClientId :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("FetchEvent"), "resultingClientId", wj.new_string(ctx, "")) }
@(export, link_name = "wjr_FetchEvent_get_replacesClientId")  wjr_FetchEvent_get_replacesClientId  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("FetchEvent"), "replacesClientId", wj.new_string(ctx, "")) }
@(export, link_name = "wjr_FetchEvent_get_preloadResponse")   wjr_FetchEvent_get_preloadResponse   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("FetchEvent"), "_preload", wj.web_promise_take(ctx, wj.UNDEFINED)) }
@(export, link_name = "wjr_FetchEvent_get_handled")           wjr_FetchEvent_get_handled           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj.wj_this(ctx, t, ifc("FetchEvent")) != nil ? wj.web_promise_take(ctx, wj.UNDEFINED) : wj.EXCEPTION }

@(export, link_name = "wjr_FetchEvent_respondWith")
wjr_FetchEvent_respondWith :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("FetchEvent")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "FetchEvent.respondWith", 1, argc) }
	if wj.web_event_host(t) == 0 { return wj.wj_throw_dom(ctx, "InvalidStateError", "The event handler is already finished.") }
	prev := wj.web_extra_get(ctx, t, "_respond")
	again := !wj.is_undefined(prev)
	wj.JS_FreeValue(ctx, prev)
	if again { return wj.wj_throw_dom(ctx, "InvalidStateError", "The event has already been responded to.") }
	wj.web_extra_set(ctx, t, "_respond", wj.JS_DupValue(ctx, argv[0]))
	return lifetime_add(ctx, t, argv[0]) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_ExtendableMessageEvent_get_data")        wjr_ExtendableMessageEvent_get_data        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("ExtendableMessageEvent"), "data", wj.NULL) }
@(export, link_name = "wjr_ExtendableMessageEvent_get_origin")      wjr_ExtendableMessageEvent_get_origin      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("ExtendableMessageEvent"), "origin", wj.new_string(ctx, "")) }
@(export, link_name = "wjr_ExtendableMessageEvent_get_lastEventId") wjr_ExtendableMessageEvent_get_lastEventId :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("ExtendableMessageEvent"), "lastEventId", wj.new_string(ctx, "")) }
@(export, link_name = "wjr_ExtendableMessageEvent_get_source")      wjr_ExtendableMessageEvent_get_source      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("ExtendableMessageEvent"), "source", wj.NULL) }
@(export, link_name = "wjr_ExtendableMessageEvent_get_ports")       wjr_ExtendableMessageEvent_get_ports       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or(ctx, t, ifc("ExtendableMessageEvent"), "ports", wj.JS_NewArray(ctx)) }

// ---- firing the browser's events ----

// install / activate settled: data = [kind]; `code` 1: done (a failed install: 0).
@(private = "file")
extend_settled :: proc "contextless" (ctx: ^wj.Context, kind: i32, code: i64) {
	context = wj.heap_context()
	reply(kind == i32(Sw_Event.Install) ? .Install_Done : .Activate_Done, 0, code)
}


// The Response read: data = [id, status, headers, url] and the body in argv[0].
@(private = "file")
body_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	id: i64
	status: i32 = 200
	wj.JS_ToInt64(ctx, &id, data[0])
	wj.JS_ToInt32(ctx, &status, data[1])
	hc, headers := to_text(ctx, data[2])
	uc, url := to_text(ctx, data[3])
	bytes: [^]u8
	n: uint
	if argc < 1 || !wj.wj_to_buffer_source(ctx, argv[0], &bytes, &n, 0, "respondWith") { wj.drop_exception(ctx); bytes = nil; n = 0 }
	reply(.Respond, u64(id), i64(status), headers, url, bytes != nil ? bytes[:n] : nil)
	if hc != nil { wj.JS_FreeCString(ctx, hc) }
	if uc != nil { wj.JS_FreeCString(ctx, uc) }
	return wj.UNDEFINED
}

@(private = "file")
respond_failed :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	id: i64
	wj.JS_ToInt64(ctx, &id, data[0])
	c: cstring
	why: string = "respondWith's promise rejected"
	if argc > 0 {
		if cc, s := to_text(ctx, argv[0]); cc != nil { c, why = cc, s }
	}
	reply(.Fail, u64(id), 0, text = why)
	if c != nil { wj.JS_FreeCString(ctx, c) }
	return wj.UNDEFINED
}

// respondWith's promise fulfilled: a Response, read whole.
@(private = "file")
respond_value :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	resp := wj.arg(argc, argv, 0)
	id: i64
	wj.JS_ToInt64(ctx, &id, data[0])
	if wj.wj_unwrap(resp, ifc("Response")) == nil {
		reply(.Fail, u64(id), 0, text = "respondWith was given something that is not a Response")
		return wj.UNDEFINED
	}
	type := wj.JS_GetPropertyStr(ctx, resp, "type")
	tc, ty := to_text(ctx, type)
	error := tc != nil && ty == "error"
	if tc != nil { wj.JS_FreeCString(ctx, tc) }
	wj.JS_FreeValue(ctx, type)
	if error { reply(.Fail, u64(id), 0, text = "Response.error()"); return wj.UNDEFINED }
	sv := wj.JS_GetPropertyStr(ctx, resp, "status")
	status: i32 = 200
	wj.JS_ToInt32(ctx, &status, sv)
	wj.JS_FreeValue(ctx, sv)
	if status == 0 { status = 200 }   // an opaque response: the page sees it as one it may not read anyway
	hv := wj.JS_GetPropertyStr(ctx, resp, "headers")
	lines: wj.Web_Buf
	web_headers_serialize(hv, &lines)
	wj.JS_FreeValue(ctx, hv)
	ab_fn := wj.JS_GetPropertyStr(ctx, resp, "arrayBuffer")
	body := wj.JS_Call(ctx, ab_fn, resp, 0, nil)
	wj.JS_FreeValue(ctx, ab_fn)
	d := [4]wj.JSValue{wj.JS_DupValue(ctx, data[0]), wj.new_int32(status), wj.new_string_len(ctx, wj.web_buf_bytes(&lines)), wj.JS_GetPropertyStr(ctx, resp, "url")}
	wj.web_buf_free(&lines)
	r := wj.is_exception(body) ? wj.EXCEPTION : wj.web_then(ctx, body, rawptr(body_read), rawptr(respond_failed), 4, &d[0])
	if wj.is_exception(r) {
		wj.drop_exception(ctx)
		reply(.Fail, u64(id), 0, text = "the response's body could not be read")
	}
	wj.free_values(ctx, r, body, d[0], d[1], d[2], d[3])
	return wj.UNDEFINED
}

// Fetch modes and destinations as the browser numbers them (fetch.Mode, fetch.Destination).
@(private = "file") MODE_NAMES := [?]cstring{"navigate", "same-origin", "no-cors", "cors"}
@(private = "file") DEST_NAMES := [?]cstring{"", "document", "script", "style", "image", "font", "audio", "video", "manifest", "report", "worker", "iframe", "frame"}

@(private = "file")
make_request :: proc(ctx: ^wj.Context, info: ^wj.wr_SwEventInfo) -> wj.JSValue {
	text: string
	jsb.host(&text, api_decl.SwEvent_text, wj.wr_SwEvent_text, i32(0))
	url := wj.new_string_len(ctx, text)
	init := wj.JS_NewObject(ctx)
	jsb.host(&text, api_decl.SwEvent_text, wj.wr_SwEvent_text, i32(1))
	bodyless := text == "GET" || text == "HEAD"
	wj.JS_SetPropertyStr(ctx, init, "method", wj.new_string_len(ctx, text))
	jsb.host(&text, api_decl.SwEvent_text, wj.wr_SwEvent_text, i32(2))
	headers := web_headers_new(ctx, .None)
	web_headers_fill_lines(ctx, headers, raw_data(text), uint(len(text)))
	wj.JS_SetPropertyStr(ctx, init, "headers", headers)
	if info.mode > 0 && info.mode < 4 { wj.JS_SetPropertyStr(ctx, init, "mode", wj.new_string(ctx, MODE_NAMES[info.mode])) }
	if !bodyless {
		body: abi.Bytes
		jsb.host(&body, api_decl.SwEvent_body, wj.wr_SwEvent_body)
		if len(body) > 0 { wj.JS_SetPropertyStr(ctx, init, "body", wj.JS_NewArrayBufferCopy(ctx, raw_data(body), uint(len(body)))) }
	}
	ctor := global_prop(ctx, "Request")
	args := [2]wj.JSValue{url, init}
	r := wj.JS_CallConstructor(ctx, ctor, 2, &args[0])
	wj.free_values(ctx, ctor, url, init)
	if info.mode == 0 && !wj.is_exception(r) { web_request_set_mode(r, 3) }   // a navigation: mode "navigate"
	if info.destination > 0 && int(info.destination) < len(DEST_NAMES) && !wj.is_exception(r) {
		web_request_set_destination(r, DEST_NAMES[info.destination])
	}
	return r
}

// Navigation preloads waiting for their response: fetch id and the resolving functions of preloadResponse.
@(private = "file") Preload :: struct { id: u64, promise: Prom }
@(private = "file") preloads: [dynamic]Preload

@(private = "file")
preload_promise :: proc(ctx: ^wj.Context, id: u64) -> wj.JSValue {
	p := Preload{id = id, promise = PROM_NONE}
	prom_new(ctx, &p.promise)
	if wj.is_exception(p.promise.p) { return p.promise.p }
	r := wj.JS_DupValue(ctx, p.promise.p)
	if append(&preloads, p) != 1 { prom_clear(ctx, &p.promise) }
	return r
}

// The preload's response came (mode 0: it failed): preloadResponse settles.
@(private = "file")
fire_preload :: proc(ctx: ^wj.Context, info: ^wj.wr_SwEventInfo) {
	at := -1
	for p, i in preloads { if p.id == info.id { at = i; break } }
	if at < 0 { return }
	prom := preloads[at].promise
	unordered_remove(&preloads, at)
	defer prom_clear(ctx, &prom)
	if info.mode == 0 {
		e := wj.web_type_error(ctx, "the navigation preload request failed")
		prom_reject(ctx, &prom, e)
		wj.JS_FreeValue(ctx, e)
		return
	}
	text: string
	jsb.host(&text, api_decl.SwEvent_text, wj.wr_SwEvent_text, i32(0))
	url := clone_string(text)
	defer if url != "" { delete(url, wj.libc_allocator()) }
	jsb.host(&text, api_decl.SwEvent_text, wj.wr_SwEvent_text, i32(2))
	headers := web_headers_new(ctx, .None)
	web_headers_fill_lines(ctx, headers, raw_data(text), uint(len(text)))
	status := info.mode
	null_body := status == 101 || status == 103 || status == 204 || status == 205 || status == 304
	body := wj.NULL
	if !null_body {
		bytes: abi.Bytes
		jsb.host(&bytes, api_decl.SwEvent_body, wj.wr_SwEvent_body)
		body = wj.JS_NewArrayBufferCopy(ctx, raw_data(bytes), uint(len(bytes)))
	}
	init := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, init, "status", wj.new_int32(status < 200 || status > 599 ? 200 : status))
	wj.JS_SetPropertyStr(ctx, init, "headers", headers)
	ctor := global_prop(ctx, "Response")
	args := [2]wj.JSValue{body, init}
	r := wj.JS_CallConstructor(ctx, ctor, 2, &args[0])
	wj.free_values(ctx, ctor, body, init)
	if wj.is_exception(r) {
		r = wj.JS_GetException(ctx)
		prom_reject(ctx, &prom, r)
	} else {
		if url != "" { web_response_set_url(ctx, r, raw_data(url), uint(len(url))) }
		prom_resolve(ctx, &prom, r)
	}
	wj.JS_FreeValue(ctx, r)
}

@(private = "file")
fire_fetch :: proc(ctx: ^wj.Context, info: ^wj.wr_SwEventInfo) {
	req := make_request(ctx, info)
	if wj.is_exception(req) { wj.wj_report_pending(ctx); reply(.Fall_Back, info.id, 0); return }
	ev := wj.web_event_new(ctx, ifc("FetchEvent"), "fetch", false, true)
	if wj.is_exception(ev) { wj.JS_FreeValue(ctx, req); wj.wj_report_pending(ctx); reply(.Fall_Back, info.id, 0); return }
	defer wj.JS_FreeValue(ctx, ev)
	cid: [24]u8
	client := info.client != 0 ? id_text(info.client, &cid) : ""
	wj.web_extra_set(ctx, ev, "request", req)
	wj.web_extra_set(ctx, ev, "clientId", wj.new_string_len(ctx, info.mode == 0 ? "" : client))
	wj.web_extra_set(ctx, ev, "resultingClientId", wj.new_string(ctx, ""))
	wj.web_extra_set(ctx, ev, "_preload", info.flags & 1 != 0 ? preload_promise(ctx, info.id) : wj.web_promise_take(ctx, wj.UNDEFINED))
	wj.web_event_fire(ctx, wj.realm_global(), ev)
	p := wj.web_extra_get(ctx, ev, "_respond")
	defer wj.JS_FreeValue(ctx, p)
	if wj.is_undefined(p) {
		reply(.Fall_Back, info.id, 0)
		return
	}
	pr := promise_call(ctx, "resolve", p)
	d := wj.new_int64(ctx, i64(info.id))
	r := wj.is_exception(pr) ? wj.EXCEPTION : wj.web_then(ctx, pr, rawptr(respond_value), rawptr(respond_failed), 1, &d)
	if wj.is_exception(r) { wj.drop_exception(ctx); reply(.Fail, info.id, 0, text = "respondWith") }
	wj.free_values(ctx, r, pr)
}

@(private = "file")
fire_extendable :: proc(ctx: ^wj.Context, kind: Sw_Event) {
	install := kind == .Install
	ev := wj.web_event_new(ctx, install ? ifc("InstallEvent") : ifc("ExtendableEvent"), install ? "install" : "activate", false, false)
	if wj.is_exception(ev) {
		wj.wj_report_pending(ctx)
		reply(install ? .Install_Done : .Activate_Done, 0, kind == .Activate ? 1 : 0)
		return
	}
	defer wj.JS_FreeValue(ctx, ev)
	wj.web_event_fire(ctx, wj.realm_global(), ev)
	if extra_int(ctx, ev, "_pending") > 0 {
		wj.web_extra_set(ctx, ev, "_settle", wj.new_int32(i32(kind) + 1))
	} else {
		lifetime_finish(ctx, ev, i32(kind))
	}
}

@(private = "file")
fire_message :: proc(ctx: ^wj.Context, info: ^wj.wr_SwEventInfo) {
	text: string
	jsb.host(&text, api_decl.SwEvent_text, wj.wr_SwEvent_text, i32(0))
	// the source: the window client that posted (its URL came with the message)
	url := text[:min(len(text), 2048)]
	line: [dynamic]u8
	defer delete(line)
	// (a worker client's id is 1 << 40 and above: src/page/service_worker.odin SW_WORKER_CLIENT_BASE)
	worker := info.client >= 1 << 40
	cid: [24]u8
	append(&line, id_text(info.client, &cid))
	append(&line, '\t')
	append(&line, url)
	append(&line, worker ? "\tworker\tnone\thidden\t0" : "\twindow\ttop-level\tvisible\t1")
	body: abi.Bytes
	jsb.host(&body, api_decl.SwEvent_body, wj.wr_SwEvent_body)
	value := web_clone_deserialize(ctx, raw_data(body), uint(len(body)))
	bad := wj.is_exception(value)
	if bad { wj.drop_exception(ctx); value = wj.NULL }
	ev := wj.web_event_new(ctx, ifc("ExtendableMessageEvent"), bad ? "messageerror" : "message", false, false)
	if wj.is_exception(ev) { wj.JS_FreeValue(ctx, value); wj.wj_report_pending(ctx); return }
	defer wj.JS_FreeValue(ctx, ev)
	wj.web_extra_set(ctx, ev, "data", value)
	wj.web_extra_set(ctx, ev, "origin", global_prop(ctx, "origin"))
	if info.client != 0 {
		src := client_from_line(ctx, string(line[:min(len(line), 2199)]))
		if wj.is_exception(src) { wj.drop_exception(ctx) } else { wj.web_extra_set(ctx, ev, "source", src) }
	}
	wj.web_event_fire(ctx, wj.realm_global(), ev)
}

// The browser: events wait for this service worker (SwEvent_next).
@(export, link_name = "wj_sw_event")
wj_sw_event :: proc "c" () {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	for {
		info: wj.wr_SwEventInfo
		wj.wr_SwEvent_next(&info)
		kind := Sw_Event(info.kind)
		if kind == .None { break }
		#partial switch kind {
		case .Install, .Activate:
			fire_extendable(ctx, kind)
		case .Fetch:
			fire_fetch(ctx, &info)
		case .Message:
			fire_message(ctx, &info)
		case .Answer:
			t: string
			jsb.host(&t, api_decl.SwEvent_text, wj.wr_SwEvent_text, i32(0))
			text := clone_string(t)
			answer(ctx, info.id, info.mode == 0, text)
			if text != "" { delete(text, wj.libc_allocator()) }
		case .Registration:
			refresh(ctx)
		case .Preload:
			fire_preload(ctx, &info)
		}
		jsb.host(&none, api_decl.SwEvent_done, wj.wr_SwEvent_done)
	}
}

// ---- the global of a service worker's realm (a ServiceWorkerGlobalScope: the realm starts with that scope, so its
// oninstall / onactivate / onfetch / onmessage handlers are the generated ones) ----

@(export, link_name = "wjr_ServiceWorkerGlobalScope_skipWaiting")
wjr_ServiceWorkerGlobalScope_skipWaiting :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("ServiceWorkerGlobalScope")) == nil { return wj.web_promise_reject_pending(ctx) }
	reply(.Skip_Waiting, 0, 0)
	return wj.web_promise_take(ctx, wj.UNDEFINED)
}

@(export, link_name = "wjr_ServiceWorkerGlobalScope_get_clients")
wjr_ServiceWorkerGlobalScope_get_clients :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("ServiceWorkerGlobalScope")) == nil { return wj.EXCEPTION }
	return wj.wj_new_object(ctx, ifc("Clients"), nil, nil)   // [SameObject]: kept by the binding
}

@(export, link_name = "wjr_ServiceWorkerGlobalScope_get_registration")
wjr_ServiceWorkerGlobalScope_get_registration :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("ServiceWorkerGlobalScope")) == nil { return wj.EXCEPTION }
	reg: u64
	jsb.host(&reg, api_decl.ServiceWorkerGlobalScope_registration, wj.wr_ServiceWorkerGlobalScope_registration)
	return registration_of(ctx, reg)
}

@(export, link_name = "wjr_ServiceWorkerGlobalScope_get_serviceWorker")
wjr_ServiceWorkerGlobalScope_get_serviceWorker :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, t, ifc("ServiceWorkerGlobalScope")) == nil { return wj.EXCEPTION }
	version: u64
	jsb.host(&version, api_decl.ServiceWorkerGlobalScope_version, wj.wr_ServiceWorkerGlobalScope_version)
	return sw_object_of(ctx, version)
}
