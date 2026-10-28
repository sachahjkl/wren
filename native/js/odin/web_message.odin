// web_message.odin: MessageChannel and MessagePort (HTML "channel messaging"), and window.postMessage to the window
// itself (a page posts to itself as a fast task queue; other windows are frames.c's). Ported from
// native/js/runtime/web_message.c; same wjr_* symbols, same exports (wj_port_message), same helpers for the C that
// stays (web_ship_ports, web_receive_ports, web_message_event_ports, web_port_remote, web_bound_add / _remove).
//
// A message is structured-serialized when posted (clone.odin; transferred ArrayBuffers are detached) and delivered from
// a task of its own as a "message" MessageEvent; a port delivers once started (start(), or setting onmessage), keeping
// what arrived before in order. The serialized bytes become the ArrayBuffer the task carries without a copy (the
// buffer takes over the libc block). Ports are EventTargets of the browser (listeners).
//
// A port sent to another realm (in the transfer list of another window's or a worker's postMessage, or of a remote
// port's message) is shipped (web_ship_ports): its pair becomes a pair of port ends the browser routes
// (src/page/ports.odin), the port left here talks to its end, and the receiving realm gets a new port bound to the
// other end (wj_port_message). The ends bound to objects of this realm (ports and BroadcastChannels) are kept in a
// table, counted: an object that may still receive stays alive, as HTML keeps an entangled port whose other side lives.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") if_message_port, if_message_channel, if_message_event, if_broadcast := i32(-2), i32(-2), i32(-2), i32(-2)
@(private = "file") nothing: abi.Nothing

// The state of a MessagePort.
@(private = "file")
Port :: struct {
	peer:    wj.JSValue,          // the entangled port of this realm (counted), undefined once closed or shipped
	queue:   [dynamic]wj.JSValue, // what arrived before start(): serialized messages (ArrayBuffers) or remote MessageEvents (counted)
	started: bool,
	closed:  bool,
	end:     u64,                 // the browser's port end when the other side is in another realm (0: a pair of this realm)
}

@(private = "file")
port_free :: proc "c" (p: rawptr) {
	context = m4_context()
	pt := (^Port)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, pt.peer)
	for m in pt.queue { wj.JS_FreeValueRT(rt, m) }
	delete(pt.queue)
	wj.libc_free(pt)
}

@(private = "file")
port_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	pt := (^Port)(p)
	wj.wj_mark(rt, pt.peer, mark_func)
	for m in pt.queue { wj.wj_mark(rt, m, mark_func) }
}

@(private = "file")
port_of :: proc "contextless" (v: wj.JSValue) -> ^Port {
	return (^Port)(wj.impl_of(wj.wj_unwrap(v, iface_lazy(&if_message_port, "MessagePort"))))
}

@(private = "file")
port_new :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	context = m4_context()
	target: abi.Handle
	jsb.host(&target, api_decl.EventTarget_create, wj.wr_EventTarget_create)
	obj := wj.wj_wrap_owned(ctx, u64(target), iface_lazy(&if_message_port, "MessagePort"), wj.UNDEFINED)
	if wj.is_exception(obj) { return obj }
	p := (^Port)(wj.libc_calloc(1, size_of(Port)))
	if p == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	p.peer = wj.UNDEFINED
	p.queue.allocator = wj.libc_allocator()
	wj.web_set_impl(obj, p, port_free, port_mark)
	return obj
}

// m appended to a port's waiting queue (counted)
@(private = "file")
enqueue :: proc(ctx: ^wj.Context, pt: ^Port, m: wj.JSValue) {
	if _, err := append(&pt.queue, wj.JS_DupValue(ctx, m)); err != nil { wj.JS_FreeValue(ctx, m) }
}

// ---- MessageChannel ----

@(private = "file")
Channel :: struct { ports: [2]wj.JSValue }

@(private = "file")
channel_free :: proc "c" (p: rawptr) {
	c := (^Channel)(p)
	wj.JS_FreeValueRT(wj.web_rt(), c.ports[0])
	wj.JS_FreeValueRT(wj.web_rt(), c.ports[1])
	wj.libc_free(p)
}

@(private = "file")
channel_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	c := (^Channel)(p)
	wj.wj_mark(rt, c.ports[0], mark_func)
	wj.wj_mark(rt, c.ports[1], mark_func)
}

@(export, link_name = "wjr_MessageChannel_constructor")
wjr_MessageChannel_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor MessageChannel requires 'new'") }
	c := (^Channel)(wj.libc_calloc(1, size_of(Channel)))
	if c == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	c.ports[0] = port_new(ctx)
	if wj.is_exception(c.ports[0]) { wj.libc_free(c); return wj.EXCEPTION }
	c.ports[1] = port_new(ctx)
	if wj.is_exception(c.ports[1]) { wj.JS_FreeValue(ctx, c.ports[0]); wj.libc_free(c); return wj.EXCEPTION }
	port_of(c.ports[0]).peer = wj.JS_DupValue(ctx, c.ports[1])
	port_of(c.ports[1]).peer = wj.JS_DupValue(ctx, c.ports[0])
	obj := wj.wj_new_object_for(ctx, iface_lazy(&if_message_channel, "MessageChannel"), new_target, nil, nil)
	if wj.is_exception(obj) { channel_free(c); return obj }
	wj.web_set_impl(obj, c, channel_free, channel_mark)
	return obj
}

@(private = "file")
channel_port :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, i: int) -> wj.JSValue {
	c := (^Channel)(wj.web_this_impl(ctx, this_val, iface_lazy(&if_message_channel, "MessageChannel")))
	return c != nil ? wj.JS_DupValue(ctx, c.ports[i]) : wj.EXCEPTION
}
@(export, link_name = "wjr_MessageChannel_get_port1")
wjr_MessageChannel_get_port1 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return channel_port(ctx, this_val, 0) }
@(export, link_name = "wjr_MessageChannel_get_port2")
wjr_MessageChannel_get_port2 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return channel_port(ctx, this_val, 1) }

// ---- delivery ----

// A queued message fired at `target`: a remote MessageEvent as is, or a serialized message (an ArrayBuffer of the
// bytes) as a "message" MessageEvent ("messageerror" when it cannot be deserialized).
@(private = "file")
deliver :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue, bytes: wj.JSValue, origin: cstring, source: wj.JSValue) {
	if is_a(bytes, &if_message_event, "MessageEvent") { wj.web_event_fire(ctx, target, bytes); return }
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, bytes, &p, &n, 0, "message") { wj.wj_report_pending(ctx); return }
	data := web_clone_deserialize(ctx, p, n)
	ev: wj.JSValue
	if wj.is_exception(data) {
		wj.drop_exception(ctx)
		ev = wj.web_event_new(ctx, iface_lazy(&if_message_event, "MessageEvent"), "messageerror", false, false)
	} else {
		ev = web_message_event(ctx, data, origin, source)
		wj.JS_FreeValue(ctx, data)
	}
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	wj.web_event_fire(ctx, target, ev)
	wj.JS_FreeValue(ctx, ev)
}

// What arrived before start(), delivered in order (a listener may close the port meanwhile: the rest is dropped).
@(private = "file")
port_drain :: proc "c" (ctx: ^wj.Context, port: wj.JSValue) {
	context = m4_context()
	pt := port_of(port)
	if pt == nil || !pt.started || pt.closed { return }
	q := pt.queue
	pt.queue = make([dynamic]wj.JSValue, wj.libc_allocator())
	defer delete(q)
	for m in q {
		pt = port_of(port)
		if pt != nil && !pt.closed { deliver(ctx, port, m, "", wj.NULL) }
		wj.JS_FreeValue(ctx, m)
	}
}

// the task of a message posted to a port of this realm: data = [port, bytes]
@(private = "file")
port_task :: proc "c" (ctx: ^wj.Context, data: wj.JSValue) {
	context = m4_context()
	port := wj.JS_GetPropertyUint32(ctx, data, 0)
	bytes := wj.JS_GetPropertyUint32(ctx, data, 1)
	if pt := port_of(port); pt != nil && !pt.closed {
		if pt.started { deliver(ctx, port, bytes, "", wj.NULL) } else { enqueue(ctx, pt, bytes) }
	}
	free_values(ctx, port, bytes)
}

// the ArrayBuffer of a libc block it takes over (freed with it)
@(private = "file")
libc_ab_realloc :: proc "c" (rt: ^wj.Runtime, opaque: rawptr, ptr: rawptr, size: uint) -> rawptr {
	if size == 0 { wj.libc_free(ptr); return nil }
	return wj.libc_realloc(ptr, size)
}

// The serialized message as an ArrayBuffer, the transfer done: EXCEPTION otherwise.
@(private = "file")
serialize_message :: proc "contextless" (ctx: ^wj.Context, message: wj.JSValue, transfer_arg: wj.JSValue, options: bool) -> wj.JSValue {
	transfer := web_transfer_list(ctx, transfer_arg, options)
	if wj.is_exception(transfer) { return transfer }
	defer wj.JS_FreeValue(ctx, transfer)
	n: uint
	p := web_clone_serialize(ctx, message, &n)
	if p == nil { return wj.EXCEPTION }
	ab := wj.JS_NewArrayBuffer(ctx, p, n, 0, libc_ab_realloc, nil, false)
	if wj.is_exception(ab) { web_clone_free(ctx, p); return ab }
	web_transfer_detach(ctx, transfer)
	return ab
}

// ---- port ends bound to objects of this realm ----

@(private = "file")
Bound :: struct { end: u64, obj: wj.JSValue }   // obj counted
@(private = "file") bound: [dynamic]Bound

// The object bound to the browser's end `end` (not counted), or undefined.
@(private = "file")
bound_find :: proc "contextless" (end: u64) -> wj.JSValue {
	for b in bound { if b.end == end { return b.obj } }
	return wj.UNDEFINED
}

// The table of ends bound to objects of this realm (ports here, BroadcastChannels in web_broadcast.odin).
@(export, link_name = "web_bound_add")
web_bound_add :: proc "c" (ctx: ^wj.Context, end: u64, obj: wj.JSValue) {
	context = m4_context()
	if bound.allocator.procedure == nil { bound.allocator = wj.libc_allocator() }
	append(&bound, Bound{end, wj.JS_DupValue(ctx, obj)})
}

@(export, link_name = "web_bound_remove")
web_bound_remove :: proc "c" (end: u64) {
	context = m4_context()
	for b, i in bound {
		if b.end != end { continue }
		unordered_remove(&bound, i)
		wj.JS_FreeValueRT(wj.web_rt(), b.obj)   // (may drop the last reference to the object: done last)
		return
	}
}

// A new port of this realm talking to the browser's port `end` (taken by this realm).
@(private = "file")
port_new_remote :: proc "contextless" (ctx: ^wj.Context, end: u64) -> wj.JSValue {
	context = m4_context()
	port := port_new(ctx)
	if wj.is_exception(port) { jsb.host(&nothing, api_decl.Port_close, wj.wr_Port_close, end); return port }
	pt := port_of(port)
	pt.end = end
	if jsb.host(&nothing, api_decl.Port_bind, wj.wr_Port_bind, end) != .None { pt.end = 0; pt.closed = true; return port }
	web_bound_add(ctx, end, port)
	return port
}

// A port of this realm bound to the browser's port end `end` (a SharedWorker's port, a connect event's port). An end of
// 0 gives a closed port.
@(export, link_name = "web_port_remote")
web_port_remote :: proc "c" (ctx: ^wj.Context, end: u64) -> wj.JSValue {
	if end != 0 { return port_new_remote(ctx, end) }
	port := port_new(ctx)
	if !wj.is_exception(port) { port_of(port).closed = true }
	return port
}

// Ships the ports of a message (an array, transfer order) out of this realm: each one's pair becomes a pair of port ends
// (the port that stays here, if any, talks to the first), and the ports themselves are neutered. The ends travel with
// the message (a libc block, free()d by the caller; nil when there are none). False with a DataCloneError pending for a
// port that cannot go.
ship_ports :: proc "contextless" (ctx: ^wj.Context, ports: wj.JSValue) -> ([]u64, bool) {
	context = m4_context()
	count: i64
	if !wj.JS_IsArray(ports) || wj.JS_GetLength(ctx, ports, &count) < 0 || count == 0 { return nil, true }
	out := ([^]u64)(wj.libc_calloc(uint(count), size_of(u64)))
	if out == nil { wj.JS_ThrowOutOfMemory(ctx); return nil, false }
	for i in 0 ..< count {
		p := wj.JS_GetPropertyUint32(ctx, ports, u32(i))
		defer wj.JS_FreeValue(ctx, p)
		pt := port_of(p)
		if pt == nil || pt.closed {
			for k in 0 ..< i { jsb.host(&nothing, api_decl.Port_close, wj.wr_Port_close, out[k]) }
			wj.libc_free(out)
			wj.wj_throw_dom(ctx, "DataCloneError", "A MessagePort could not be transferred: it is closed or was transferred already.")
			return nil, false
		}
		if pt.end != 0 {
			out[i] = pt.end
			jsb.host(&nothing, api_decl.Port_ship, wj.wr_Port_ship, pt.end)
			web_bound_remove(pt.end)
			pt.end = 0
		} else {
			a: u64
			jsb.host(&a, api_decl.Port_entangle, wj.wr_Port_entangle)
			out[i] = a + 1
			q := port_of(pt.peer)
			if q != nil && !q.closed && a != 0 {
				// the port that stays here now talks to the first end
				qv := wj.JS_DupValue(ctx, pt.peer)
				wj.JS_FreeValue(ctx, q.peer)
				q.peer = wj.UNDEFINED
				q.end = a
				if jsb.host(&nothing, api_decl.Port_bind, wj.wr_Port_bind, a) == .None { web_bound_add(ctx, a, qv) } else { q.end = 0 }
				wj.JS_FreeValue(ctx, qv)
			} else if a != 0 {
				jsb.host(&nothing, api_decl.Port_close, wj.wr_Port_close, a)
			}
		}
		// the port sent is neutered
		pt.closed = true
		wj.JS_FreeValue(ctx, pt.peer)
		pt.peer = wj.UNDEFINED
	}
	return out[:count], true
}

@(export, link_name = "web_ship_ports")
web_ship_ports :: proc "c" (ctx: ^wj.Context, ports: wj.JSValue, ends: ^[^]u64, n: ^u32) -> bool {
	list, ok := ship_ports(ctx, ports)
	ends^ = raw_data(list)
	n^ = u32(len(list))
	return ok
}

// The received ports of a message (ends in the engine's memory): new ports of this realm bound to them.
@(export, link_name = "web_receive_ports")
web_receive_ports :: proc "c" (ctx: ^wj.Context, ends: [^]u64, n: u32) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< n {
		p := port_new_remote(ctx, ends[i])
		if wj.is_exception(p) { wj.drop_exception(ctx); continue }
		wj.array_set(ctx, arr, i, p)
	}
	return arr
}

// A MessageEvent with data, origin, source and ports (frozen).
@(export, link_name = "web_message_event_ports")
web_message_event_ports :: proc "c" (ctx: ^wj.Context, data: wj.JSValue, origin: cstring, source: wj.JSValue, ports: wj.JSValue) -> wj.JSValue {
	ev := web_message_event(ctx, data, origin, source)
	if wj.is_exception(ev) || !wj.JS_IsArray(ports) { return ev }
	copy := wj.JS_DupValue(ctx, ports)
	freeze(ctx, copy)
	wj.web_extra_set(ctx, ev, "ports", copy)
	return ev
}

// postMessage on a port whose other side is in another realm: serialized with its ports shipped, posted to the end.
@(private = "file")
remote_post :: proc "contextless" (ctx: ^wj.Context, pt: ^Port, message: wj.JSValue, second: wj.JSValue, options: bool) -> wj.JSValue {
	context = m4_context()
	transfer := wj.UNDEFINED
	if options {
		if wj.is_object(second) {
			transfer = wj.JS_GetPropertyStr(ctx, second, "transfer")
			if wj.is_exception(transfer) { return transfer }
		}
	} else {
		transfer = wj.JS_DupValue(ctx, second)
	}
	n: uint
	ports := wj.UNDEFINED
	bytes := wj_clone_serialize_ports(ctx, message, transfer, &n, &ports)
	wj.JS_FreeValue(ctx, transfer)
	if bytes == nil { return wj.EXCEPTION }
	defer wj.libc_free(bytes)
	ends, ok := ship_ports(ctx, ports)
	wj.JS_FreeValue(ctx, ports)
	if !ok { return wj.EXCEPTION }
	defer wj.libc_free(raw_data(ends))
	st := abi.Api_Error.None
	if !pt.closed && pt.end != 0 {
		st = jsb.host(&nothing, api_decl.Port_post, wj.wr_Port_post, pt.end, abi.Bytes(bytes[:n]), ends)
	}
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "MessagePort.postMessage") }
	return wj.UNDEFINED
}

// The browser delivers a message for the object bound to `end` (src/page/ports.odin), with the ends of the ports that
// came with it: a MessageEvent at the port (kept until the port is started), or the message of a BroadcastChannel.
@(export, link_name = "wj_port_message")
wj_port_message :: proc "c" (end_lo, end_hi, data, data_len, ends, n_ends: u32) {
	context = m4_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	end := u64(end_lo) | u64(end_hi) << 32
	// the ends are read before any JavaScript runs (they are in the browser's call buffer)
	list := make([]u64, n_ends, wj.libc_allocator())
	if n_ends != 0 && list == nil { return }
	copy(list, ([^]u64)(uintptr(ends))[:n_ends])
	ports := web_receive_ports(ctx, raw_data(list), n_ends)
	delete(list, wj.libc_allocator())
	port := wj.JS_DupValue(ctx, bound_find(end))
	defer wj.JS_FreeValue(ctx, port)
	bytes := ([^]u8)(uintptr(data))
	if is_a(port, &if_broadcast, "BroadcastChannel") {
		wj.JS_FreeValue(ctx, ports)
		web_broadcast_deliver(ctx, port, bytes, uint(data_len))
		return
	}
	pt := port_of(port)
	value := wj_clone_deserialize_ports(ctx, bytes, uint(data_len), ports)
	ev: wj.JSValue
	if wj.is_exception(value) {
		wj.drop_exception(ctx)
		ev = wj.web_event_new(ctx, iface_lazy(&if_message_event, "MessageEvent"), "messageerror", false, false)
	} else {
		ev = web_message_event_ports(ctx, value, "", wj.NULL, ports)
		wj.JS_FreeValue(ctx, value)
	}
	wj.JS_FreeValue(ctx, ports)
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	defer wj.JS_FreeValue(ctx, ev)
	if pt != nil && !pt.closed {
		if pt.started { wj.web_event_fire(ctx, port, ev) } else { enqueue(ctx, pt, ev) }
	}
}

// ---- MessagePort ----

@(private = "file")
port_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Port {
	return (^Port)(wj.web_this_impl(ctx, this_val, iface_lazy(&if_message_port, "MessagePort")))
}

@(export, link_name = "wjr_MessagePort_postMessage")
wjr_MessagePort_postMessage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	pt := port_this(ctx, this_val)
	if pt == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "MessagePort.postMessage", 1, argc) }
	second := wj.arg(argc, argv, 1)
	// postMessage(message, transfer) or postMessage(message, {transfer})
	seq := wj.is_object(second) && wj.web_is_iterable(ctx, second) > 0
	if pt.end != 0 { return remote_post(ctx, pt, argv[0], second, !seq) }
	bytes := serialize_message(ctx, argv[0], second, !seq)
	if wj.is_exception(bytes) { return bytes }
	defer wj.JS_FreeValue(ctx, bytes)
	if !pt.closed && wj.is_object(pt.peer) {
		data := wj.JS_NewArray(ctx)
		wj.array_set(ctx, data, 0, wj.JS_DupValue(ctx, pt.peer))
		wj.array_set(ctx, data, 1, wj.JS_DupValue(ctx, bytes))
		ok := wj.web_queue_task(ctx, port_task, data)
		wj.JS_FreeValue(ctx, data)
		if !ok { return wj.EXCEPTION }
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_MessagePort_start")
wjr_MessagePort_start :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	pt := port_this(ctx, this_val)
	if pt == nil { return wj.EXCEPTION }
	if pt.started { return wj.UNDEFINED }
	pt.started = true
	// what arrived before is delivered from a task, in order
	if len(pt.queue) > 0 && !wj.web_queue_task(ctx, port_drain, this_val) { return wj.EXCEPTION }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_MessagePort_close")
wjr_MessagePort_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	pt := port_this(ctx, this_val)
	if pt == nil { return wj.EXCEPTION }
	pt.closed = true
	if pt.end != 0 {
		end := pt.end
		pt.end = 0
		jsb.host(&nothing, api_decl.Port_close, wj.wr_Port_close, end)
		web_bound_remove(end)
	}
	// disentangled both ways
	if peer := port_of(pt.peer); peer != nil { wj.JS_FreeValue(ctx, peer.peer); peer.peer = wj.UNDEFINED }
	wj.JS_FreeValue(ctx, pt.peer)
	pt.peer = wj.UNDEFINED
	return wj.UNDEFINED
}

// onmessage = f starts the port (HTML "message port message queue" is enabled by the onmessage setter)
@(export, link_name = "wjr_MessagePort_set_onmessage")
wjr_MessagePort_set_onmessage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	r := wj.wj_event_handler_set(ctx, this_val, iface_lazy(&if_message_port, "MessagePort"), "message", v, 0)
	if wj.is_exception(r) { return r }
	return wjr_MessagePort_start(ctx, this_val, 0, nil)
}

// ---- window.postMessage ----

// the task of a message the window posted to itself: data = [bytes, origin]
@(private = "file")
window_task :: proc "c" (ctx: ^wj.Context, data: wj.JSValue) {
	bytes := wj.JS_GetPropertyUint32(ctx, data, 0)
	origin := wj.JS_GetPropertyUint32(ctx, data, 1)
	o := wj.to_cstring(ctx, origin)
	deliver(ctx, wj.realm_global(), bytes, o != nil ? o : "", wj.realm_global())
	if o != nil { wj.free_cstring(ctx, o) }
	free_values(ctx, origin, bytes)
}

// Whether targetOrigin lets the message through: "*" and "/" do; a URL must have this window's origin. False with a
// SyntaxError pending for a target that is not a URL (*bad).
@(private = "file")
origin_matches :: proc(ctx: ^wj.Context, to: wj.Str, own: string, own_ok: bool, bad: ^bool) -> bool {
	target := str_view(to)
	if target == "*" || target == "/" { return true }
	u: api_decl.URL
	if jsb.host(&u, api_decl.URL_parse, wj.wr_URL_parse, target, Maybe(string)(nil)) != .None {
		bad^ = true
		return false
	}
	origin: string
	st := jsb.host(&origin, api_decl.URL_get, wj.wr_URL_get, u, api_decl.URLComponent.Origin)
	same := own_ok && st == .None && origin == own   // (compared before the release: the result is in the scratch buffer)
	jsb.host(&nothing, api_decl.Object_release, wj.wr_Object_release, u64(u))
	return same
}

@(export, link_name = "wjr_Window_postMessage")
wjr_Window_postMessage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "postMessage", 1, argc) }
	second := wj.arg(argc, argv, 1)
	target_origin, transfer := wj.UNDEFINED, wj.UNDEFINED
	defer free_values(ctx, target_origin, transfer)
	options := !wj.is_string(second) && !wj.is_undefined(second)
	if options {
		// postMessage(message, {targetOrigin, transfer})
		if !wj.web_dict_check(ctx, second, "postMessage") || !wj.web_dict_get(ctx, second, "targetOrigin", &target_origin) { return wj.EXCEPTION }
		transfer = wj.JS_DupValue(ctx, second)
	} else {
		target_origin = wj.JS_DupValue(ctx, second)
		transfer = wj.JS_DupValue(ctx, wj.arg(argc, argv, 2))
	}
	own := wj.global_get(ctx, "origin")
	defer wj.JS_FreeValue(ctx, own)
	own_c, own_s := to_text(ctx, own)
	defer if own_c != nil { wj.free_cstring(ctx, own_c) }
	deliver_it := true
	if !wj.is_undefined(target_origin) {
		to: wj.Str
		if !wj.wj_to_str(ctx, target_origin, &to, 0, nil) { return wj.EXCEPTION }
		bad := false
		deliver_it = origin_matches(ctx, to, own_s, own_c != nil, &bad)
		wj.wj_str_free(ctx, &to)
		if bad { return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'postMessage' on 'Window': Invalid target origin.") }
	}
	bytes := serialize_message(ctx, argv[0], transfer, options)
	if wj.is_exception(bytes) { return bytes }
	defer wj.JS_FreeValue(ctx, bytes)
	if deliver_it {
		data := wj.JS_NewArray(ctx)
		wj.array_set(ctx, data, 0, wj.JS_DupValue(ctx, bytes))
		wj.array_set(ctx, data, 1, wj.JS_DupValue(ctx, own))
		ok := wj.web_queue_task(ctx, window_task, data)
		wj.JS_FreeValue(ctx, data)
		if !ok { return wj.EXCEPTION }
	}
	return wj.UNDEFINED
}
