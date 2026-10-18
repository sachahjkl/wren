package page

// WebSocket (WHATWG WebSockets): a host object and EventTarget over fetch/websocket.odin (policy) and
// net/websocket.odin (transport). The specification's rules live here:
//
//   * Constructor: SyntaxError (handle 0) for a bad URL, a fragment, a non-ws(s) scheme, or invalid / duplicate
//     protocols. A connection refused by policy (CSP, mixed content, bad port...) is not an exception: "error" then
//     "close" (1006, not clean) arrive from a task.
//   * readyState CONNECTING (0) -> OPEN (1) -> CLOSING (2) -> CLOSED (3). send() while CONNECTING is an
//     InvalidStateError; after close() the bytes are discarded but still added to bufferedAmount. A send that would
//     exceed websocket.max_buffered_bytes closes the connection (the specification's "buffer is full").
//   * close(code, reason): InvalidAccessError unless the code is 1000 or 3000-4999, SyntaxError for a reason over 123
//     bytes. While CONNECTING it fails the connection.
//   * Events: "open"; "message" (text in Event_data; binary as a buffer handle in Event_object, owned by the guest, who
//     releases it with Object_release); "error" when the connection failed or closed abnormally; "close" with Event_code,
//     the reason in Event_text and CloseEvent_wasClean. MessageEvent_origin is the origin of the socket's URL.
//   * binaryType is "arraybuffer" (0) only: there are no blobs on this platform.

import "core:strings"
import "core:unicode/utf8"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:url"

// DOMException codes returned (negated) by the network APIs; they never collide with dom.Error.
Net_Api_Error :: enum i32 {
	Not_Supported  = -9,
	Invalid_State  = -11,
	Syntax         = -12,
	Invalid_Access = -15,
}

Websocket_Settings :: struct {
	limits:       net.Ws_Limits,
	max_buffered: int,
}

WEBSOCKET_PREFS := [?]config.Def{
	{name = "websocket.max_connections_total", kind = .Int, default = {i = 200}, bounded = true, min = 1, max = 65_536,
		description = "WebSockets alive at once in the browser (all pages). Opening more fails with an error and a close event."},
	{name = "websocket.max_connecting_per_host", kind = .Int, default = {i = 1}, bounded = true, min = 1, max = 256,
		description = "Handshakes in progress to one host:port (RFC 6455 asks for 1). Further sockets wait their turn in order."},
	{name = "websocket.handshake_timeout_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "Time allowed from the start of a handshake to the server's 101 answer. 0 = no limit (the network timeouts still apply)."},
	{name = "websocket.close_timeout_ms", kind = .Int, default = {i = 10_000}, bounded = true, min = 100, max = 3_600_000, unit = "ms",
		description = "Wait for the server's close frame after the browser sent its own; past it the connection is dropped (close event not clean)."},
	{name = "websocket.keepalive_interval_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 15_000, max = 3_600_000, unit = "ms",
		description = "Interval of the keep-alive packets on an idle WebSocket (the operating system's minimum is 15 s)."},
	{name = "websocket.max_message_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 1024, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Largest message a page may receive. A bigger one fails the connection (the page's memory budget, page.max_fetch_bytes, applies too)."},
	{name = "websocket.receive_chunk_bytes", kind = .Int, default = {i = 64 << 10}, bounded = true, min = 1024, max = 16 << 20, bytes = true, unit = "bytes",
		description = "Size of one read from the network for a WebSocket."},
	{name = "websocket.receive_high_water_bytes", kind = .Int, default = {i = 4 << 20}, bounded = true, min = 4096, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Back-pressure: reading a WebSocket pauses when this many received bytes wait for the page."},
	{name = "websocket.receive_low_water_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Back-pressure: reading resumes when the bytes waiting for the page fall below this."},
	{name = "websocket.send_fragment_bytes", kind = .Int, default = {i = 256 << 10}, bounded = true, min = 1024, max = 64 << 20, bytes = true, unit = "bytes",
		description = "Messages larger than this are sent as several frames of at most this size."},
	{name = "websocket.max_buffered_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 1024, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Most bytes a page may queue on one WebSocket (bufferedAmount). A send beyond it closes the connection, as the specification requires when the buffer is full."},
}

websocket_settings_from_prefs :: proc(p: ^config.Prefs) -> Websocket_Settings {
	s: Websocket_Settings
	l := &s.limits
	l.max_total = int(config.int_of(p, "websocket.max_connections_total"))
	l.max_connecting_per_host = int(config.int_of(p, "websocket.max_connecting_per_host"))
	l.handshake_timeout_ms = int(config.int_of(p, "websocket.handshake_timeout_ms"))
	l.close_timeout_ms = int(config.int_of(p, "websocket.close_timeout_ms"))
	l.keepalive_ms = int(config.int_of(p, "websocket.keepalive_interval_ms"))
	l.max_message = int(config.int_of(p, "websocket.max_message_bytes"))
	l.receive_chunk = int(config.int_of(p, "websocket.receive_chunk_bytes"))
	l.high_water = int(config.int_of(p, "websocket.receive_high_water_bytes"))
	l.low_water = min(int(config.int_of(p, "websocket.receive_low_water_bytes")), l.high_water)
	l.send_fragment = int(config.int_of(p, "websocket.send_fragment_bytes"))
	s.max_buffered = int(config.int_of(p, "websocket.max_buffered_bytes"))
	return s
}

WS_CONNECTING :: 0
WS_OPEN       :: 1
WS_CLOSING    :: 2
WS_CLOSED     :: 3

Web_Socket :: struct {
	page:         ^Page,
	self:         u64,
	owner:        u32,
	href:         string,   // owned
	origin:       string,   // owned
	protocol:     string,   // owned
	extensions:   string,   // owned
	state:        i32,
	sock:         base.Handle,
	buffered:     i64,
	was_clean:    bool,
	timer:        base.Handle,   // a failure reported from a task
}

websocket_vt := Object_VTable{name = "WebSocket", destroy = websocket_destroy}

@(private)
websocket_destroy :: proc(p: ^Page, data: rawptr) {
	w := (^Web_Socket)(data)
	if w.sock != base.NIL_HANDLE { fetch.websocket_abort(p.loader, w.sock) }   // dropped like a collected socket
	if w.timer != base.NIL_HANDLE { host.clear_timer(p.loop, w.timer) }
	delete(w.href); delete(w.origin); delete(w.protocol); delete(w.extensions)
	free(w)
}

websocket_get :: proc(p: ^Page, h: u64) -> ^Web_Socket { return (^Web_Socket)(object_data(p, h, &websocket_vt)) }

// new WebSocket(url, protocols). 0 = SyntaxError.
websocket_create :: proc(p: ^Page, owner: u32, input: string, protocols: []string) -> u64 {
	u, ok := fetch.websocket_parse_url(input, &p.env.location, context.temp_allocator)
	if !ok || !fetch.websocket_protocols_valid(protocols) { return 0 }
	w := new(Web_Socket)
	w.page, w.owner = p, owner
	w.href = strings.clone(u.href)
	w.origin = url.origin_serialize(url.origin_of(u, context.temp_allocator))
	w.self = object_create(p, &websocket_vt, w, owner)
	sock, err, detail := fetch.websocket_connect(p.loader, {
		url = w.href, protocols = protocols, initiator = &p.env, on_event = websocket_event, user = w, scope = p.scope,
		limits = p.settings.websocket.limits,
	})
	if err != .None {
		log(p, .Error, strings.concatenate({"WebSocket ", w.href, ": ", detail}, context.temp_allocator))
		websocket_fail_later(w)
	} else {
		w.sock = sock
	}
	return w.self
}

// The connection failed outside of a network event (policy, close() while connecting, full buffer): CLOSED, "error"
// and "close" arrive from a task, never inside the guest's own call.
@(private)
websocket_fail_later :: proc(w: ^Web_Socket) {
	if w.sock != base.NIL_HANDLE { fetch.websocket_abort(w.page.loader, w.sock); w.sock = base.NIL_HANDLE }
	if w.state < WS_CLOSING { w.state = WS_CLOSING }
	if w.timer != base.NIL_HANDLE { return }
	w.timer = host.set_timer(w.page.loop, 0, 0, proc(data: rawptr) {
		ws := (^Web_Socket)(data)
		ws.timer = base.NIL_HANDLE
		websocket_finish(ws, 1006, "", false, true)
	}, w, w.page.scope)
}

@(private)
websocket_finish :: proc(w: ^Web_Socket, code: u16, reason: string, clean, with_error: bool) {
	p, self := w.page, w.self
	if w.state == WS_CLOSED { return }
	w.state = WS_CLOSED
	w.sock = base.NIL_HANDLE
	w.was_clean = clean
	if w.timer != base.NIL_HANDLE { host.clear_timer(p.loop, w.timer); w.timer = base.NIL_HANDLE }
	if with_error {
		object_dispatch(p, self, dom.Event{type = "error"})
		if websocket_get(p, self) != w { return }
	}
	object_dispatch(p, self, dom.Event{type = "close", code = i64(code), text = reason})
}

@(private)
websocket_event :: proc(user: rawptr, sock: base.Handle, ev: ^fetch.Socket_Event) {
	w := (^Web_Socket)(user)
	p, self := w.page, w.self
	switch ev.kind {
	case .Open:
		w.state = WS_OPEN
		delete(w.protocol); w.protocol = strings.clone(ev.protocol)
		delete(w.extensions); w.extensions = strings.clone(ev.extensions)
		object_dispatch(p, self, dom.Event{type = "open"})
	case .Message:
		if w.state != WS_OPEN { return }   // messages after close() are dropped, as specified
		if !ev.binary {
			object_dispatch(p, self, dom.Event{type = "message", data = string(ev.data)})
			return
		}
		if !object_has_listener(p, self, "message") { return }   // nobody would own the buffer
		b := buffer_create(p, ev.data, w.owner)
		if b == 0 {
			log(p, .Error, strings.concatenate({"WebSocket ", w.href, ": message dropped, the page memory limit (page.max_fetch_bytes) is reached"}, context.temp_allocator))
			websocket_fail_later(w)
			return
		}
		object_dispatch(p, self, dom.Event{type = "message", object = b})
	case .Sent:
		w.buffered = max(w.buffered - i64(ev.sent), 0)
	case .Closing:
		if w.state == WS_OPEN { w.state = WS_CLOSING }
	case .Closed:
		websocket_finish(w, ev.code, ev.reason, ev.clean, !ev.clean)
	case .Failed:
		log(p, .Error, strings.concatenate({"WebSocket ", w.href, ": ", ev.detail}, context.temp_allocator))
		websocket_finish(w, 1006, "", false, true)
	}
}

// send() for text (UTF-8, invalid sequences replaced as a USVString conversion would) and binary data.
websocket_send :: proc(w: ^Web_Socket, data: []byte, binary: bool) -> i32 {
	if w.state == WS_CONNECTING { return i32(Net_Api_Error.Invalid_State) }
	payload := data
	if !binary && !utf8.valid_string(string(data)) { payload = transmute([]byte)usv_string(string(data)) }
	n := i64(len(payload))
	if w.state != WS_OPEN {
		w.buffered += n   // discarded, but counted (the specification wants scripts to see it grow)
		return 0
	}
	if w.buffered + n > i64(w.page.settings.websocket.max_buffered) {
		log(w.page, .Error, strings.concatenate({"WebSocket ", w.href, ": the send buffer is full (websocket.max_buffered_bytes)"}, context.temp_allocator))
		w.buffered += n
		websocket_fail_later(w)
		return 0
	}
	w.buffered += n
	if !fetch.websocket_send(w.page.loader, w.sock, payload, binary) { return 0 }
	return 0
}

// close(code?, reason?). `code` < 0 = absent.
websocket_close :: proc(w: ^Web_Socket, code: int, reason: string) -> i32 {
	switch fetch.websocket_close_check(code, code >= 0, reason) {
	case .Invalid_Access: return i32(Net_Api_Error.Invalid_Access)
	case .Syntax:         return i32(Net_Api_Error.Syntax)
	case .Ok:
	}
	switch w.state {
	case WS_CLOSING, WS_CLOSED:
		return 0
	case WS_CONNECTING:
		websocket_fail_later(w)
		return 0
	}
	w.state = WS_CLOSING
	wire: u16 = code >= 0 ? u16(code) : (reason != "" ? 1000 : net.WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS)
	if !fetch.websocket_close(w.page.loader, w.sock, wire, reason) { websocket_fail_later(w) }
	return 0
}

@(private)
usv_string :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in s { strings.write_rune(&sb, r) }   // iteration yields U+FFFD for each invalid sequence
	return strings.to_string(sb)
}
