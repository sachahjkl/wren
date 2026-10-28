// web_socket.odin: WebSocket and CloseEvent (WebSockets Standard), EventSource (HTML server-sent events), and
// MessageEvent, on the browser's sockets and event sources (modules websocket, eventsource). Ported from
// native/js/runtime/web_socket.c: same wjr_* symbols, same exports (wj_cb_socket), same helpers for the rest of the
// glue (web_message_event, web_message_event_named).
//
// Each socket or event source listens to its own events first (an internal listener registered at construction): a
// binary message's buffer becomes an ArrayBuffer or a Blob (binaryType) at once, and the browser's buffer is released
// whether a script reads event.data or not; the object is kept alive while it may still fire events (until "close" for
// a socket, until CLOSED for an event source), as HTML's garbage collection rules ask.
//
// Every call into the browser is a declaration of api_decl/websocket.odin (or of the modules dom and async) through
// jsb.host; what is written here is behaviour.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") none: abi.Nothing

// The state of a WebSocket or an EventSource.
@(private = "file")
Socket :: struct {
	blob:      bool,   // binaryType "blob" (the default) or "arraybuffer"
	is_source: bool,
	pin:       u32,
	slot:      u32,
}

// The internal listeners: slot -> the object (not counted; cleared when the wrapper dies). Slot 0 is never used.
@(private = "file") sock_slots: [dynamic]^wj.Obj

@(private = "file")
sock_slot :: proc(o: ^wj.Obj) -> u32 {
	for i in 1 ..< len(sock_slots) {
		if sock_slots[i] == nil { sock_slots[i] = o; return u32(i) }
	}
	if len(sock_slots) == 0 && append(&sock_slots, nil) != 1 { return 0 }
	if append(&sock_slots, o) != 1 { return 0 }
	return u32(len(sock_slots) - 1)
}

@(private = "file")
socket_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	s := (^Socket)(p)
	if s.slot != 0 && int(s.slot) < len(sock_slots) { sock_slots[s.slot] = nil }
	free(s)
}

// ---- the data of message events made before any listener reads them (host event -> value) ----

@(private = "file")
Pending :: struct {
	event: api_decl.Event,
	data:  wj.JSValue,
}

@(private = "file") pending: [dynamic]Pending

// Drops the data of events the browser has forgotten.
@(private = "file")
pending_prune :: proc(ctx: ^wj.Context) {
	w := 0
	for p in pending {
		live: bool
		jsb.host(&live, api_decl.Event_isLive, wj.wr_Event_isLive, p.event)
		if live { pending[w] = p; w += 1; continue }
		wj.JS_FreeValue(ctx, p.data)
	}
	resize(&pending, w)
}

@(private = "file")
pending_put :: proc(ctx: ^wj.Context, event: api_decl.Event, data: wj.JSValue) {
	pending_prune(ctx)
	if append(&pending, Pending{event, data}) != 1 { wj.JS_FreeValue(ctx, data) }
}

// The data kept for `event`; UNINITIALIZED when there is none.
@(private = "file")
pending_take :: proc(event: api_decl.Event) -> wj.JSValue {
	for p, i in pending {
		if p.event != event { continue }
		unordered_remove(&pending, i)
		return p.data
	}
	return wj.UNINITIALIZED
}

@(private = "file")
socket_listen :: proc(h: u64, slot: u32, type: string) {
	id: i32
	jsb.host(&id, api_decl.EventTarget_addEventListener, wj.wr_EventTarget_addEventListener, api_decl.EventTarget(h), type,
		wj.table_index(rawptr(wj_cb_socket)), i32(slot), u32(0))
}

// The kinds of event the internal listener tells apart.
@(private = "file") Event_Kind :: enum { Other, Message, Close, Error }

// The internal listener of sockets and event sources.
@(export, link_name = "wj_cb_socket")
wj_cb_socket :: proc "c" (user: i32, event: u64) {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if user <= 0 || int(user) >= len(sock_slots) || sock_slots[user] == nil { return }
	o := sock_slots[user]
	s := (^Socket)(o.impl)
	if s == nil { return }
	ev := api_decl.Event(event)
	type: string
	jsb.host(&type, api_decl.Event_type, wj.wr_Event_type, ev)
	kind: Event_Kind
	switch type {
	case "message": kind = .Message
	case "close":   kind = .Close
	case "error":   kind = .Error
	}
	switch {
	case kind == .Message && !s.is_source:
		buf: api_decl.Buffer
		jsb.host(&buf, api_decl.WebSocket_messageBuffer, wj.wr_Event_object, ev)
		if buf == 0 { return }
		data: wj.JSValue
		if s.blob {
			n: i64
			jsb.host(&n, api_decl.Buffer_length, wj.wr_Buffer_length, buf)
			bytes := make([]u8, max(int(n), 1), wj.libc_allocator())
			defer delete(bytes, wj.libc_allocator())
			if bytes == nil {
				data = wj.JS_ThrowOutOfMemory(ctx)
			} else {
				got: i32
				if n > 0 { jsb.host(&got, api_decl.Buffer_read, wj.wr_Buffer_read, buf, i64(0), bytes[:n]) }
				data = web_blob_new(ctx, raw_data(bytes), uint(max(got, 0)), "", 0)
			}
		} else {
			data = wj.wj_arraybuffer_from_host(ctx, u64(buf))
		}
		jsb.host(&none, api_decl.Object_release, wj.wr_Object_release, abi.Handle(buf))
		if wj.is_exception(data) { wj.wj_report_pending(ctx); return }
		pending_put(ctx, ev, data)
	case kind == .Close && !s.is_source:
		if s.pin != 0 { pin := s.pin; s.pin = 0; wj.web_unpin_later(ctx, pin) }
	case kind == .Error && s.is_source:
		state: api_decl.EventSourceState
		jsb.host(&state, api_decl.EventSource_readyState, wj.wr_EventSource_readyState, api_decl.EventSource(o.handle))
		if s.pin != 0 && state == .Closed { pin := s.pin; s.pin = 0; wj.web_unpin_later(ctx, pin) }
	}
}

// ---- WebSocket ----

// The comma-separated subprotocols of new WebSocket(url, protocols).
@(private = "file")
Protocols :: struct {
	text: [dynamic]u8,
	n:    u32,
}

@(private = "file")
protocol_add :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	context = wj.heap_context()
	ps := (^Protocols)(opaque)
	s: wj.Str
	if !wj.wj_to_str(ctx, item, &s, 0, nil) { return false }
	defer wj.wj_str_free(ctx, &s)
	if ps.n > 0 { append(&ps.text, ',') }
	ps.n += 1
	append(&ps.text, ..wj.str_slice(s))
	return true
}

@(export, link_name = "wjr_WebSocket_constructor")
wjr_WebSocket_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor WebSocket requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "WebSocket", 1, argc) }
	u: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &u) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &u)
	ps: Protocols
	defer delete(ps.text)
	pv := wj.arg(argc, argv, 1)
	ok := true
	if wj.is_object(pv) {
		ok = wj.web_for_of(ctx, pv, protocol_add, &ps)
	} else if !wj.is_undefined(pv) {
		ok = protocol_add(ctx, pv, &ps)
	}
	if !ok { return wj.EXCEPTION }
	ws: api_decl.WebSocket
	if st := jsb.host(&ws, api_decl.WebSocket_create, wj.wr_WebSocket_create, str_view(u), string(ps.text[:])); st != .None {
		if st == .Syntax { return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to construct 'WebSocket': The URL or a subprotocol is invalid.") }
		return wj.wj_throw_status(ctx, i32(st), "WebSocket")
	}
	h := u64(ws)
	obj := wj.wj_wrap_owned(ctx, h, jsb.iface_of(api_decl.WebSocket), new_target)
	if wj.is_exception(obj) { return obj }
	s := new(Socket)
	if s == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	s.blob = true
	wj.web_set_impl(obj, s, socket_free, nil)
	s.slot = sock_slot(wj.obj_of(obj))
	if s.slot != 0 {
		socket_listen(h, s.slot, "message")
		socket_listen(h, s.slot, "close")
	}
	s.pin = wj.web_pin(ctx, obj)
	return obj
}

@(private = "file")
socket_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Obj {
	o := wj.wj_this(ctx, this_val, jsb.iface_of(api_decl.WebSocket))
	if o != nil && (o.impl == nil || o.handle == 0) { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return o
}

@(export, link_name = "wjr_WebSocket_get_binaryType")
wjr_WebSocket_get_binaryType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := socket_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	return wj.new_string(ctx, (^Socket)(o.impl).blob ? "blob" : "arraybuffer")
}

@(export, link_name = "wjr_WebSocket_set_binaryType")
wjr_WebSocket_set_binaryType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	o := socket_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	c, text := to_text(ctx, v)
	if c == nil { return wj.EXCEPTION }
	defer wj.JS_FreeCString(ctx, c)
	// an enum attribute: other values are ignored
	switch text {
	case "blob":        (^Socket)(o.impl).blob = true
	case "arraybuffer": (^Socket)(o.impl).blob = false
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_WebSocket_send")
wjr_WebSocket_send :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	o := socket_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "WebSocket.send", 1, argc) }
	ws := api_decl.WebSocket(o.handle)
	bytes: [^]u8
	n: uint
	binary := web_blob_bytes(argv[0], &bytes, &n)
	if !binary && wj.wj_is_buffer_source(argv[0]) {
		binary = wj.wj_to_buffer_source(ctx, argv[0], &bytes, &n, 0, "WebSocket.send")
	}
	st: abi.Api_Error
	if binary {
		buf := wj.wj_host_buffer(ctx, bytes, n)
		if buf == 0 { return wj.EXCEPTION }
		st = jsb.host(&none, api_decl.WebSocket_sendBuffer, wj.wr_WebSocket_sendBuffer, ws, api_decl.Buffer(buf))
		jsb.host(&none, api_decl.Object_release, wj.wr_Object_release, abi.Handle(buf))
	} else {
		if wj.JS_HasException(ctx) { return wj.EXCEPTION }
		s: wj.Str
		if !wj.web_to_usv(ctx, argv[0], &s) { return wj.EXCEPTION }
		st = jsb.host(&none, api_decl.WebSocket_send, wj.wr_WebSocket_send, ws, str_view(s))
		wj.wj_str_free(ctx, &s)
	}
	if st != .None {
		if st == .Invalid_State { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.") }
		return wj.wj_throw_status(ctx, i32(st), "WebSocket.send")
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_WebSocket_close")
wjr_WebSocket_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	o := socket_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	code := i32(-1)
	cv, rv := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)
	if !wj.is_undefined(cv) {
		c: u32
		if !wj.wj_to_uint32(ctx, cv, &c, 16, wj.CLAMP) { return wj.EXCEPTION }
		code = i32(c)
	}
	r: wj.Str
	if !wj.is_undefined(rv) && !wj.web_to_usv(ctx, rv, &r) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &r)
	if st := jsb.host(&none, api_decl.WebSocket_close, wj.wr_WebSocket_close, api_decl.WebSocket(o.handle), code, str_view(r)); st != .None {
		#partial switch st {
		case .Invalid_Access:
			return wj.wj_throw_dom(ctx, "InvalidAccessError", "Failed to execute 'close' on 'WebSocket': The close code must be either 1000, or between 3000 and 4999.")
		case .Syntax:
			return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'close' on 'WebSocket': The close reason must not be greater than 123 UTF-8 bytes.")
		}
		return wj.wj_throw_status(ctx, i32(st), "WebSocket.close")
	}
	return wj.UNDEFINED
}

// ---- CloseEvent ----

// The members of a CloseEvent, kept in the event's hidden state once the browser's event has been read.
@(private = "file") Close_Field :: enum { Code, Reason, Was_Clean }
@(private = "file") CLOSE_FIELD_NAMES := [Close_Field]cstring{.Code = "code", .Reason = "reason", .Was_Clean = "wasClean"}

@(private = "file")
close_field :: proc(ctx: ^wj.Context, this_val: wj.JSValue, field: Close_Field) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("CloseEvent")) == nil { return wj.EXCEPTION }
	name := CLOSE_FIELD_NAMES[field]
	v := wj.web_extra_get(ctx, this_val, name)
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	if h == 0 {
		switch field {
		case .Code:      return wj.new_int32(0)
		case .Reason:    return wj.new_string(ctx, "")
		case .Was_Clean: return wj.FALSE
		}
	}
	ev := api_decl.Event(h)
	reason: string
	jsb.host(&reason, api_decl.Event_text, wj.wr_Event_text, ev)
	wj.web_extra_set(ctx, this_val, "reason", wj.new_string_len(ctx, reason))
	code: i64
	jsb.host(&code, api_decl.Event_code, wj.wr_Event_code, h)
	wj.web_extra_set(ctx, this_val, "code", wj.new_int32(i32(code)))
	clean: bool
	jsb.host(&clean, api_decl.CloseEvent_wasClean, wj.wr_CloseEvent_wasClean, ev)
	wj.web_extra_set(ctx, this_val, "wasClean", wj.new_bool(clean))
	return wj.web_extra_get(ctx, this_val, name)
}

@(export, link_name = "wjr_CloseEvent_get_code")
wjr_CloseEvent_get_code :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return close_field(ctx, this_val, .Code)
}
@(export, link_name = "wjr_CloseEvent_get_reason")
wjr_CloseEvent_get_reason :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return close_field(ctx, this_val, .Reason)
}
@(export, link_name = "wjr_CloseEvent_get_wasClean")
wjr_CloseEvent_get_wasClean :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return close_field(ctx, this_val, .Was_Clean)
}

@(export, link_name = "wjr_CloseEvent_constructor")
wjr_CloseEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj_event_construct(ctx, new_target, argc, argv, ifc("CloseEvent"), "CloseEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	clean, code, reason: wj.JSValue
	if !wj.web_dict_get(ctx, init, "wasClean", &clean) || !wj.web_dict_get(ctx, init, "code", &code) || !wj.web_dict_get(ctx, init, "reason", &reason) {
		wj.JS_FreeValue(ctx, ev)
		return wj.EXCEPTION
	}
	wj.web_extra_set(ctx, ev, "wasClean", wj.new_bool(wj.JS_ToBool(ctx, clean) != 0))
	wj.JS_FreeValue(ctx, clean)
	c: u32
	ok := wj.is_undefined(code) || wj.wj_to_uint32(ctx, code, &c, 16, 0)
	wj.JS_FreeValue(ctx, code)
	if !ok { wj.free_values(ctx, reason, ev); return wj.EXCEPTION }
	wj.web_extra_set(ctx, ev, "code", wj.new_int32(i32(c)))
	rs := wj.is_undefined(reason) ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, reason)
	wj.JS_FreeValue(ctx, reason)
	if wj.is_exception(rs) { wj.JS_FreeValue(ctx, ev); return rs }
	wj.web_extra_set(ctx, ev, "reason", rs)
	return ev
}

// ---- EventSource ----

@(export, link_name = "wjr_EventSource_constructor")
wjr_EventSource_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor EventSource requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "EventSource", 1, argc) }
	u: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &u) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &u)
	opt := wj.arg(argc, argv, 1)
	wc: wj.JSValue
	if !wj.web_dict_check(ctx, opt, "EventSource") || !wj.web_dict_get(ctx, opt, "withCredentials", &wc) { return wj.EXCEPTION }
	creds := wj.JS_ToBool(ctx, wc) != 0
	wj.JS_FreeValue(ctx, wc)
	es: api_decl.EventSource
	if st := jsb.host(&es, api_decl.EventSource_create, wj.wr_EventSource_create, str_view(u), creds); st != .None {
		if st == .Syntax { return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to construct 'EventSource': The URL is invalid.") }
		return wj.wj_throw_status(ctx, i32(st), "EventSource")
	}
	h := u64(es)
	obj := wj.wj_wrap_owned(ctx, h, jsb.iface_of(api_decl.EventSource), new_target)
	if wj.is_exception(obj) { return obj }
	s := new(Socket)
	if s == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	s.is_source = true
	wj.web_set_impl(obj, s, socket_free, nil)
	s.slot = sock_slot(wj.obj_of(obj))
	if s.slot != 0 { socket_listen(h, s.slot, "error") }
	s.pin = wj.web_pin(ctx, obj)
	return obj
}

@(export, link_name = "wjr_EventSource_close")
wjr_EventSource_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(api_decl.EventSource))
	if o == nil { return wj.EXCEPTION }
	if o.handle != 0 { jsb.host(&none, api_decl.EventSource_close, wj.wr_EventSource_close, api_decl.EventSource(o.handle)) }
	if s := (^Socket)(o.impl); s != nil && s.pin != 0 {
		pin := s.pin
		s.pin = 0
		wj.web_unpin(ctx, pin)
	}
	return wj.UNDEFINED
}

// ---- MessageEvent ----

// Object.freeze(v), the result dropped.
@(private = "file")
freeze_value :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) {
	object := global_prop(ctx, "Object")
	freeze := wj.JS_GetPropertyStr(ctx, object, "freeze")
	arg := v
	frozen := wj.JS_Call(ctx, freeze, object, 1, &arg)
	wj.free_values(ctx, frozen, freeze, object)
}

// The MessagePorts that came with a worker's message event (bound to this realm the first time they are asked for, kept
// as the event's "ports"), or undefined when none came.
@(private = "file")
message_ports :: proc(ctx: ^wj.Context, ev: wj.JSValue, h: u64) -> wj.JSValue {
	have := wj.web_extra_get(ctx, ev, "ports")
	if !wj.is_undefined(have) { return have }
	packed: abi.Bytes
	jsb.host(&packed, api_decl.MessageEvent_portEnds, wj.wr_MessageEvent_portEnds, api_decl.Event(h))
	if len(packed) < 8 { return wj.UNDEFINED }
	count := len(packed) / 8
	ends := make([]u64, count, wj.libc_allocator())
	if ends == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer delete(ends, wj.libc_allocator())
	bytes := ([]u8)(packed)
	for i in 0 ..< count { ends[i] = wj.read_u64(raw_data(bytes[8 * i:])) }
	ports := web_receive_ports(ctx, raw_data(ends), u32(count))
	freeze_value(ctx, ports)
	wj.web_extra_set(ctx, ev, "ports", wj.JS_DupValue(ctx, ports))
	return ports
}

// The browser's Event_data of a message: a deserialized value (worker messages) or the text itself.
@(private = "file")
message_text_or_value :: proc(ctx: ^wj.Context, h: u64, ports: wj.JSValue) -> wj.JSValue {
	text: string
	jsb.host(&text, api_decl.Event_data, wj.wr_Event_data, api_decl.Event(h))
	if !wj_clone_is_serialized(raw_data(text), uint(len(text))) { return wj.new_string_len(ctx, text) }
	// the scratch buffer may move while deserializing: a copy
	bytes := make([]u8, max(len(text), 1), wj.libc_allocator())
	if bytes == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer delete(bytes, wj.libc_allocator())
	copy(bytes, text)
	v := wj_clone_deserialize_ports(ctx, raw_data(bytes), uint(len(text)), ports)
	if wj.is_exception(v) {
		// HTML: a message that cannot be deserialized is a messageerror; data is null
		wj.drop_exception(ctx)
		v = wj.NULL
	}
	return v
}

@(export, link_name = "wjr_MessageEvent_get_data")
wjr_MessageEvent_get_data :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, this_val, ifc("MessageEvent")) == nil { return wj.EXCEPTION }
	x := wj.web_extra(ctx, this_val, false)
	if wj.is_object(x) {
		a := wj.JS_NewAtom(ctx, "data")
		has := wj.JS_HasProperty(ctx, x, a)
		v := has > 0 ? wj.JS_GetProperty(ctx, x, a) : wj.UNDEFINED
		wj.JS_FreeAtom(ctx, a)
		wj.JS_FreeValue(ctx, x)
		if has > 0 { return v }
	} else {
		wj.JS_FreeValue(ctx, x)
	}
	h := wj.web_event_host(this_val)
	if h == 0 { return wj.NULL }
	v := pending_take(api_decl.Event(h))
	if wj.is_uninitialized(v) {
		ports := message_ports(ctx, this_val, h)
		if wj.is_exception(ports) { return ports }
		v = message_text_or_value(ctx, h, ports)
		wj.JS_FreeValue(ctx, ports)
	}
	if wj.is_exception(v) { return v }
	wj.web_extra_set(ctx, this_val, "data", wj.JS_DupValue(ctx, v))
	return v
}

// The other members read once from the browser's event and kept: origin, lastEventId, source.
@(private = "file") Message_Field :: enum { Origin, Last_Event_Id, Source }

@(private = "file")
message_field :: proc(ctx: ^wj.Context, this_val: wj.JSValue, field: Message_Field) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("MessageEvent")) == nil { return wj.EXCEPTION }
	name: cstring
	switch field {
	case .Origin:        name = "origin"
	case .Last_Event_Id: name = "lastEventId"
	case .Source:        name = "source"
	}
	v := wj.web_extra_get(ctx, this_val, name)
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	if h == 0 { return field == .Source ? wj.NULL : wj.new_string(ctx, "") }
	text: string
	switch field {
	case .Origin:        jsb.host(&text, api_decl.MessageEvent_origin, wj.wr_MessageEvent_origin, api_decl.Event(h))
	case .Last_Event_Id: jsb.host(&text, api_decl.MessageEvent_lastEventId, wj.wr_MessageEvent_lastEventId, api_decl.Event(h))
	case .Source:
	}
	v = field == .Source ? wj.NULL : wj.new_string_len(ctx, text)
	wj.web_extra_set(ctx, this_val, name, wj.JS_DupValue(ctx, v))
	return v
}

@(export, link_name = "wjr_MessageEvent_get_origin")
wjr_MessageEvent_get_origin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return message_field(ctx, this_val, .Origin)
}
@(export, link_name = "wjr_MessageEvent_get_lastEventId")
wjr_MessageEvent_get_lastEventId :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return message_field(ctx, this_val, .Last_Event_Id)
}
@(export, link_name = "wjr_MessageEvent_get_source")
wjr_MessageEvent_get_source :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return message_field(ctx, this_val, .Source)
}

@(export, link_name = "wjr_MessageEvent_get_ports")
wjr_MessageEvent_get_ports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, this_val, ifc("MessageEvent")) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, "ports")
	if !wj.is_undefined(v) { return v }
	if h := wj.web_event_host(this_val); h != 0 {
		v = message_ports(ctx, this_val, h)
		if !wj.is_undefined(v) { return v }
	}
	src := "Object.freeze([])"
	v = wj.JS_Eval(ctx, raw_data(src), uint(len(src)), "<web>", wj.EVAL_TYPE_GLOBAL)
	wj.web_extra_set(ctx, this_val, "ports", wj.JS_DupValue(ctx, v))
	return v
}

@(private = "file")
Port_List :: struct {
	arr: wj.JSValue,
	n:   u32,
}

@(private = "file")
port_add :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	pl := (^Port_List)(opaque)
	if wj.wj_unwrap(item, ifc("MessagePort")) == nil {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'MessageEvent': an item of ports is not a MessagePort.")
		return false
	}
	wj.array_set(ctx, pl.arr, pl.n, wj.JS_DupValue(ctx, item))
	pl.n += 1
	return true
}

// MessageEventInit / initMessageEvent's fields.
@(private = "file")
message_init :: proc(ctx: ^wj.Context, ev, data, origin, last_id, source, ports: wj.JSValue) -> bool {
	wj.web_extra_set(ctx, ev, "data", wj.is_undefined(data) ? wj.NULL : wj.JS_DupValue(ctx, data))
	o := wj.is_undefined(origin) ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, origin)
	if wj.is_exception(o) { return false }
	wj.web_extra_set(ctx, ev, "origin", o)
	l := wj.is_undefined(last_id) ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, last_id)
	if wj.is_exception(l) { return false }
	wj.web_extra_set(ctx, ev, "lastEventId", l)
	// the source: a Window (this one, or another document's), a MessagePort or a ServiceWorker
	if !wj.is_undefined(source) && !wj.is_null(source) && wj.wj_unwrap(source, -1) == nil && !wj.same_ptr(source, wj.realm_global()) && !wj_frames_is_window(ctx, source) {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'MessageEvent': The source is not a Window, a MessagePort or a ServiceWorker.")
		return false
	}
	wj.web_extra_set(ctx, ev, "source", wj.is_undefined(source) ? wj.NULL : wj.JS_DupValue(ctx, source))
	pl := Port_List{arr = wj.JS_NewArray(ctx)}
	if !wj.is_undefined(ports) && !wj.is_null(ports) && !wj.web_for_of(ctx, ports, port_add, &pl) {
		wj.JS_FreeValue(ctx, pl.arr)
		return false
	}
	freeze_value(ctx, pl.arr)
	wj.web_extra_set(ctx, ev, "ports", pl.arr)
	return true
}

@(export, link_name = "wjr_MessageEvent_constructor")
wjr_MessageEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	ev := wj_event_construct(ctx, new_target, argc, argv, ifc("MessageEvent"), "MessageEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	names := [5]cstring{"data", "origin", "lastEventId", "source", "ports"}
	v := [5]wj.JSValue{wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED}
	ok := true
	for i in 0 ..< 5 {
		if ok = wj.web_dict_get(ctx, init, names[i], &v[i]); !ok { break }
	}
	if ok { ok = message_init(ctx, ev, v[0], v[1], v[2], v[3], v[4]) }
	for x in v { wj.JS_FreeValue(ctx, x) }
	if !ok { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	return ev
}

@(export, link_name = "wjr_MessageEvent_initMessageEvent")
wjr_MessageEvent_initMessageEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, this_val, ifc("MessageEvent")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "MessageEvent.initMessageEvent", 1, argc) }
	init_event := wj.JS_GetPropertyStr(ctx, wj.wj_the_realm.protos[ifc("Event")], "initEvent")
	r := wj.JS_Call(ctx, init_event, this_val, min(argc, 3), argv)
	wj.JS_FreeValue(ctx, init_event)
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	if !message_init(ctx, this_val, wj.arg(argc, argv, 3), wj.arg(argc, argv, 4), wj.arg(argc, argv, 5), wj.arg(argc, argv, 6), wj.arg(argc, argv, 7)) {
		return wj.EXCEPTION
	}
	return wj.UNDEFINED
}

// A MessageEvent named `type` (a shared worker's connect) with data, origin, source and ports (frozen).
@(export, link_name = "web_message_event_named")
web_message_event_named :: proc "c" (ctx: ^wj.Context, type: cstring, data: wj.JSValue, origin: cstring, source: wj.JSValue, ports: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	ev := wj.web_event_new(ctx, ifc("MessageEvent"), type, false, false)
	if wj.is_exception(ev) { return ev }
	o := wj.new_string(ctx, origin)
	ok := message_init(ctx, ev, data, o, wj.UNDEFINED, source, ports)
	wj.JS_FreeValue(ctx, o)
	if !ok { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	return ev
}

// A MessageEvent of the engine (MessagePort, window.postMessage): data, origin and source given.
@(export, link_name = "web_message_event")
web_message_event :: proc "c" (ctx: ^wj.Context, data: wj.JSValue, origin: cstring, source: wj.JSValue) -> wj.JSValue {
	return web_message_event_named(ctx, "message", data, origin, source, wj.UNDEFINED)
}
