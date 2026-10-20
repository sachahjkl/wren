package net

// WebSockets (RFC 6455) on WinHTTP's asynchronous WebSocket API. Mechanism only: what may connect, which headers the
// handshake carries (Origin, Cookie, Sec-WebSocket-Protocol) and whether the server's answer is acceptable are decided
// by package fetch (fetch/websocket.odin). Here:
//
//   * The same threading contract as the HTTP client: WinHTTP's threads run the I/O and push raw events into a mutex
//     queue; `ws_drain` runs on the loop thread and is the only place that changes socket state or calls back.
//   * A socket is a generational handle. Aborting it, its terminal event, or closing its Scope removes it; late events
//     for it are dropped. One Ws_Job is the WinHTTP context of both the handshake request and the WebSocket handle; it is
//     reference counted by the handles that carry it and freed by the last HANDLE_CLOSING.
//   * Handshakes wait in a FIFO until their host has a free "connecting" slot (RFC 6455 §4.1: one connection in the
//     CONNECTING state per host by default). An open socket no longer counts.
//   * Receiving: messages are reassembled from WinHTTP's fragments on the loop thread, bounded by `max_message`; text is
//     validated as UTF-8. Reading pauses above `high_water` unconsumed bytes and resumes below `low_water`.
//   * Sending: one WinHTTP send in flight per socket (the API allows no more); a message larger than `send_fragment` is
//     sent as several frames. The bytes of a send in flight belong to the job, so aborting never frees them under WinHTTP.
//   * Closing: the close frame goes out after the messages already queued. A close frame from the peer is answered with
//     the same code. Our close frame is sent with WinHttpWebSocketShutdown, never WinHttpWebSocketClose: Close reads
//     the peer's close frame itself and races the receive we re-armed after the last message (when ours gets the frame,
//     Close waits for another one until its timeout: about half of the closes issued from a message handler ended in
//     "error" + 1006). Our one receive stays the only reader, so the peer's close frame always reaches us; the close is
//     clean once both frames went through, and a transport end after the peer's frame (the server cutting TCP right
//     after it) stays clean. The close timeout is our own timer. WinHTTP answers pings by itself.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import win "core:sys/windows"
import "wb:base"
import "wb:host"
import "wb:url"

// Socket-level errors that are not WinHTTP's own (below 12000, above the HTTP client's ERROR_*).
WS_ERROR_HANDSHAKE_TIMEOUT :: 20
WS_ERROR_MESSAGE_TOO_BIG   :: 21
WS_ERROR_INVALID_UTF8      :: 22
WS_ERROR_TOO_MANY          :: 23
WS_ERROR_PROTOCOL          :: 24   // e.g. a text fragment continuing a binary message
WS_ERROR_CLOSE_TIMEOUT     :: 25   // the peer's close frame did not come within close_timeout_ms

// Transport limits of one socket, normally the `websocket.*` preferences (see page/websocket.odin).
Ws_Limits :: struct {
	max_total:               int,   // sockets alive at once (all hosts); more fail at once with WS_ERROR_TOO_MANY
	max_connecting_per_host: int,   // handshakes in progress per host:port; more wait in FIFO order
	handshake_timeout_ms:    int,   // from the start of the handshake to the 101 response; 0 = none
	close_timeout_ms:        int,   // wait for the closing handshake once our close frame is issued; 0 = none
	keepalive_ms:            int,   // WinHTTP keep-alive interval; 0 = the OS default
	max_message:             int,   // largest received message
	receive_chunk:           int,   // size of one WinHTTP receive
	high_water, low_water:   int,   // receive back-pressure
	send_fragment:           int,   // largest frame sent
}

Ws_Event_Kind :: enum u8 {
	Handshake,   // the response to the upgrade request: call websocket_accept or websocket_abort
	Message,     // one complete message (`data`, `binary`)
	Sent,        // `sent` bytes left the send queue
	Closing,     // the peer started the closing handshake (`code`, `reason`)
	Closed,      // terminal: closing handshake finished (`clean`, the peer's `code`), or ended without the peer's close frame
	             // (not clean, 1006: transport error or WS_ERROR_CLOSE_TIMEOUT in `error`)
	Failed,      // terminal: `error` is a WinHTTP / WS_ERROR_* code
}

// Pointers inside an event are valid only during the callback.
Ws_Event :: struct {
	kind:         Ws_Event_Kind,
	sock:         base.Handle,
	status:       int,
	headers:      string,
	data:         []byte,
	binary:       bool,
	sent:         int,
	code:         u16,
	reason:       string,
	clean:        bool,
	error:        u32,
	secure_flags: u32,
}

Ws_Proc :: #type proc(user: rawptr, sock: base.Handle, ev: ^Ws_Event)

Ws_Desc :: struct {
	url:       string,             // ws: or wss:
	headers:   string,             // extra request headers, "Name: value\r\n..." (WinHTTP adds the Upgrade set)
	on_event:  Ws_Proc,
	user:      rawptr,
	free_user: proc(user: rawptr), // called exactly once, when the socket record goes away (whatever the path)
	scope:     ^base.Scope,        // closing it aborts the socket silently
	limits:    Ws_Limits,
}

@(private)
Socket_State :: enum u8 { Waiting, Connecting, Handshake, Open, Closing }

@(private)
Out_Msg :: struct { data: []byte, binary: bool }

@(private)
Ws_Job :: struct {
	mgr:          ^Ws_Manager,
	sock:         base.Handle,
	refs:         i32,          // atomic: WinHTTP handles carrying this job as context
	port:         u16,
	secure:       bool,
	host_w, target_w, headers_w: []u16,
	hws:          uintptr,      // atomic: the WebSocket handle, once upgraded
	recv:         []byte,
	queued:       int,          // atomic
	paused:       b32,          // atomic
	terminal:     b32,          // atomic: the handshake failed already
	high_water, low_water: int,
	send_buf:     []byte,       // the message being sent (loop thread, or HANDLE_CLOSING once released)
	close_reason: [WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON]u8,
	secure_flags: u32,
}

@(private)
Socket :: struct {
	job:        ^Ws_Job,
	hconnect, hrequest, hws: HINTERNET,
	state:      Socket_State,
	on_event:   Ws_Proc,
	user:       rawptr,
	free_user:  proc(user: rawptr),
	scope:      ^base.Scope,
	cleanup:    base.Cleanup_Id,
	limits:     Ws_Limits,
	host_key:   string,
	counted:    bool,           // holds a connecting slot of host_key
	timer:      base.Handle,
	timer_data: ^Ws_Owner,
	out:        [dynamic]Out_Msg,
	sending:    bool,
	send_off, send_len: int,
	cur_binary: bool,
	has_cur:    bool,           // a message is being sent (its bytes are job.send_buf, nil when empty)
	msg:        [dynamic]byte,
	msg_open:   bool,
	msg_binary: bool,
	close_wanted, close_issued: bool,   // issued: our close frame was handed to WinHttpWebSocketShutdown
	close_code: u16,
	close_len:  int,
	close_sent: bool,           // SHUTDOWN_COMPLETE: our close frame left
	peer_closed: bool,          // the peer's close frame was read (nothing is received after it)
	peer_code:  u16,
	peer_reason: string,        // heap
}

@(private)
Raw_Kind :: enum u8 { Headers, Handshake_Failed, Fragment, Peer_Close, Write_Done, Shutdown_Done, Error }

@(private)
Raw :: struct {
	kind:         Raw_Kind,
	sock:         base.Handle,
	status:       int,
	headers:      string,
	data:         []byte,
	btype:        Web_Socket_Buffer_Type,
	code:         u16,
	reason:       string,
	error:        u32,
	secure_flags: u32,
	op:           Web_Socket_Operation,
	n:            int,
}

Ws_Manager :: struct {
	client:        ^Client,
	sockets:       base.Pool(Socket),
	waiting:       [dynamic]base.Handle,
	connecting:    map[string]int,
	shutting_down: bool,
	orphaned:      bool,   // the client is gone; the drain still posted frees the manager
	mu:            sync.Mutex,
	events:        [dynamic]Raw,
	scratch:       [dynamic]Raw,
	drain_pending: bool,
	live_jobs:     int,   // atomic
}

@(private)
Ws_Owner :: struct { m: ^Ws_Manager, h: base.Handle }

@(private)
ws_manager :: proc(c: ^Client) -> ^Ws_Manager {
	if c.ws == nil {
		m := new(Ws_Manager, heap())
		m.client = c
		m.events = make([dynamic]Raw, heap())
		m.scratch = make([dynamic]Raw, heap())
		m.waiting = make([dynamic]base.Handle, heap())
		m.connecting = make(map[string]int, heap())
		c.ws = m
	}
	return c.ws
}

// Sockets alive (waiting, handshaking, open or closing).
websocket_count :: proc(c: ^Client) -> int { return c.ws == nil ? 0 : c.ws.sockets.count }

// Called by client_destroy before the session closes: aborts every socket and waits for WinHTTP to let go of them.
@(private)
websockets_destroy :: proc(c: ^Client) {
	m := c.ws
	if m == nil { return }
	sync.mutex_lock(&m.mu)
	m.shutting_down = true   // no new handshake starts, late callbacks are dropped
	sync.mutex_unlock(&m.mu)
	handles := make([dynamic]base.Handle, context.temp_allocator)
	it: u32
	for h, _ in base.pool_next(&m.sockets, &it) { append(&handles, h) }
	for h in handles { ws_release(m, h) }
	start := time.tick_now()
	for sync.atomic_load(&m.live_jobs) > 0 && time.duration_seconds(time.tick_since(start)) < 5 { time.sleep(time.Millisecond) }
	sync.mutex_lock(&m.mu)
	for &r in m.events { raw_free(&r) }
	clear(&m.events)
	pending := m.drain_pending
	m.orphaned = pending
	sync.mutex_unlock(&m.mu)
	base.pool_destroy(&m.sockets)
	for k in m.connecting { delete(k, heap()) }
	delete(m.connecting)
	delete(m.waiting)
	c.ws = nil
	if pending { return }   // a drain is still posted to the loop: it must find a live (empty) manager
	delete(m.events)
	delete(m.scratch)
	free(m, heap())
}

////////////////////////////////
// Loop thread: API

// Starts a WebSocket handshake. Never calls back synchronously. Returns the socket handle.
websocket_open :: proc(c: ^Client, d: Ws_Desc) -> base.Handle {
	m := ws_manager(c)
	s := Socket{on_event = d.on_event, user = d.user, free_user = d.free_user, scope = d.scope, limits = d.limits}
	s.limits.receive_chunk = max(s.limits.receive_chunk, 1024)
	s.limits.send_fragment = max(s.limits.send_fragment, 1024)
	s.limits.max_connecting_per_host = max(s.limits.max_connecting_per_host, 1)
	s.limits.low_water = min(s.limits.low_water, s.limits.high_water)
	h, sp := base.pool_insert(&m.sockets, s)
	if d.scope != nil { sp.cleanup = base.on_close(d.scope, ws_scope_closed, new_clone(Ws_Owner{m, h})) }

	u, ok := url.parse_absolute(d.url, context.temp_allocator)
	if !ok || !(u.scheme == "ws" || u.scheme == "wss") {
		ws_push(m, Raw{kind = .Handshake_Failed, sock = h, error = ERROR_BAD_URL})
		return h
	}
	if sp.limits.max_total > 0 && m.sockets.count > sp.limits.max_total {
		ws_push(m, Raw{kind = .Handshake_Failed, sock = h, error = WS_ERROR_TOO_MANY})
		return h
	}
	job := new(Ws_Job, heap())
	job.mgr = m
	job.sock = h
	job.port = u16(url.effective_port(u))
	job.secure = u.scheme == "wss"
	host_name := u.host
	if strings.has_prefix(host_name, "[") { host_name = host_name[1:len(host_name) - 1] }
	job.host_w = to_wide(host_name)
	job.target_w = to_wide(url.request_target(u, context.temp_allocator))
	if d.headers != "" { job.headers_w = to_wide(d.headers) }
	job.high_water, job.low_water = sp.limits.high_water, sp.limits.low_water
	sync.atomic_add(&m.live_jobs, 1)
	sp.job = job
	sp.host_key = strings.concatenate({u.host, ":", itoa_tmp(url.effective_port(u))}, heap())
	append(&m.waiting, h)
	ws_pump(m)
	return h
}

// Completes the upgrade after a Handshake event the caller approved. False when the socket is not waiting for it or the
// upgrade failed (a Failed event follows).
websocket_accept :: proc(c: ^Client, h: base.Handle) -> bool {
	m := c.ws
	if m == nil { return false }
	s := base.pool_get(&m.sockets, h)
	if s == nil || s.state != .Handshake { return false }
	job := s.job
	hws := WinHttpWebSocketCompleteUpgrade(s.hrequest, win.DWORD_PTR(uintptr(job)))
	if hws == nil {
		ws_push(m, Raw{kind = .Handshake_Failed, sock = h, error = u32(win.GetLastError())})
		return false
	}
	sync.atomic_add(&job.refs, 1)
	s.hws = hws
	sync.atomic_store(&job.hws, uintptr(hws))
	WinHttpSetStatusCallback(hws, ws_status_callback, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0)
	if s.limits.keepalive_ms > 0 {
		v := win.DWORD(s.limits.keepalive_ms)
		WinHttpSetOption(hws, WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL, &v, size_of(v))
	}
	WinHttpCloseHandle(s.hrequest)   // its HANDLE_CLOSING drops one reference of the job
	s.hrequest = nil
	ws_clear_timer(m, s)
	ws_leave_connecting(m, s)
	s.state = .Open
	job.recv = make([]byte, s.limits.receive_chunk, heap())
	if err := ws_receive(job, hws); err != 0 {
		ws_push(m, Raw{kind = .Error, sock = h, error = err, op = .Receive})
	}
	ws_pump(m)
	return true
}

// Queues one message. False when the socket is not open or is closing (the caller accounts for the bytes).
websocket_send :: proc(c: ^Client, h: base.Handle, data: []byte, binary: bool) -> bool {
	m := c.ws
	if m == nil { return false }
	s := base.pool_get(&m.sockets, h)
	if s == nil || s.state != .Open || s.close_wanted { return false }
	msg := Out_Msg{binary = binary}
	if len(data) > 0 { msg.data = make([]byte, len(data), heap()); copy(msg.data, data) }
	append(&s.out, msg)
	ws_pump_send(m, h, s)
	return true
}

// Bytes queued and not yet handed to the OS.
websocket_buffered :: proc(c: ^Client, h: base.Handle) -> int {
	if c.ws == nil { return 0 }
	s := base.pool_get(&c.ws.sockets, h)
	if s == nil { return 0 }
	n := 0
	for o in s.out { n += len(o.data) }
	if s.has_cur { n += len(s.job.send_buf) - s.send_off }
	return n
}

// Starts the closing handshake once the queued messages are out. `reason` is cut at 123 bytes (the caller validates).
websocket_close :: proc(c: ^Client, h: base.Handle, code: u16, reason: string) -> bool {
	m := c.ws
	if m == nil { return false }
	s := base.pool_get(&m.sockets, h)
	if s == nil || s.state != .Open || s.close_wanted { return false }
	s.close_wanted = true
	s.close_code = code
	s.close_len = copy(s.job.close_reason[:], reason)
	s.state = .Closing
	ws_try_close(m, h, s)
	return true
}

// Silent: the socket's callbacks will not run again. False if it already ended.
websocket_abort :: proc(c: ^Client, h: base.Handle) -> bool {
	if c.ws == nil { return false }
	return ws_release(c.ws, h)
}

////////////////////////////////
// Loop thread: internals

@(private)
itoa_tmp :: proc(n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_int(&sb, n)
	return strings.to_string(sb)
}

@(private)
ws_scope_closed :: proc(data: rawptr) {
	o := (^Ws_Owner)(data)
	ws_release(o.m, o.h)
	free(o)
}

@(private)
ws_pump :: proc(m: ^Ws_Manager) {
	if m.shutting_down { return }
	w := 0
	for i in 0 ..< len(m.waiting) {
		h := m.waiting[i]
		s := base.pool_get(&m.sockets, h)
		if s == nil || s.state != .Waiting { continue }
		if m.connecting[s.host_key] < s.limits.max_connecting_per_host {
			ws_begin(m, h, s)
		} else {
			m.waiting[w] = h
			w += 1
		}
	}
	resize(&m.waiting, w)
}

@(private)
ws_begin :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) {
	s.state = .Connecting
	if n, ok := m.connecting[s.host_key]; ok { m.connecting[s.host_key] = n + 1 } else { m.connecting[strings.clone(s.host_key, heap())] = 1 }
	s.counted = true
	if s.limits.handshake_timeout_ms > 0 {
		s.timer_data = new_clone(Ws_Owner{m, h})
		s.timer = host.set_timer(m.client.loop, f64(s.limits.handshake_timeout_ms), 0, ws_timeout, s.timer_data)
	}
	if code := ws_send_handshake(m, s); code != 0 {
		ws_push(m, Raw{kind = .Handshake_Failed, sock = h, error = code})
	}
}

@(private)
ws_send_handshake :: proc(m: ^Ws_Manager, s: ^Socket) -> u32 {
	c := m.client
	job := s.job
	s.hconnect = WinHttpConnect(c.session, cstring16(raw_data(job.host_w)), job.port, 0)
	if s.hconnect == nil { return u32(win.GetLastError()) }
	get := to_wide("GET")
	defer delete(get, heap())
	flags: win.DWORD = job.secure ? WINHTTP_FLAG_SECURE : 0
	s.hrequest = WinHttpOpenRequest(s.hconnect, cstring16(raw_data(get)), cstring16(raw_data(job.target_w)), nil, nil, nil, flags)
	if s.hrequest == nil { return u32(win.GetLastError()) }
	// our own callback before the context: the session's would read the job as an HTTP Job
	if transmute(uintptr)WinHttpSetStatusCallback(s.hrequest, ws_status_callback, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0) == WINHTTP_INVALID_STATUS_CALLBACK {
		return ERROR_START_FAILED
	}
	ctx := win.DWORD_PTR(uintptr(job))
	if !WinHttpSetOption(s.hrequest, WINHTTP_OPTION_CONTEXT_VALUE, &ctx, size_of(ctx)) { return ERROR_START_FAILED }
	sync.atomic_store(&job.refs, 1)
	cookies: win.DWORD = WINHTTP_DISABLE_COOKIES
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_DISABLE_FEATURE, &cookies, size_of(cookies))
	if !WinHttpSetOption(s.hrequest, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nil, 0) { return u32(win.GetLastError()) }
	// The upgrade is HTTP/1.1 only. Waiting for the 101 is bounded by our handshake timer, and an established socket may
	// stay silent for hours: the session's receive timeouts must not apply.
	h1: win.DWORD = 0
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, &h1, size_of(h1))
	infinite: win.DWORD = 0xFFFF_FFFF
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_RECEIVE_TIMEOUT, &infinite, size_of(infinite))
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT, &infinite, size_of(infinite))

	hdr: win.LPCWSTR = nil
	hdr_len: win.DWORD = 0
	if job.headers_w != nil { hdr = cstring16(raw_data(job.headers_w)); hdr_len = win.DWORD(len(job.headers_w) - 1) }
	if !WinHttpSendRequest(s.hrequest, hdr, hdr_len, nil, 0, 0, ctx) { return u32(win.GetLastError()) }
	return 0
}

@(private)
ws_timeout :: proc(data: rawptr) {
	o := (^Ws_Owner)(data)
	defer free(o)
	s := base.pool_get(&o.m.sockets, o.h)
	if s == nil || s.timer_data != o { return }
	s.timer, s.timer_data = base.NIL_HANDLE, nil
	if s.state == .Connecting || s.state == .Handshake {
		ev := Ws_Event{kind = .Failed, sock = o.h, error = WS_ERROR_HANDSHAKE_TIMEOUT}
		ws_deliver(s, &ev)
		ws_release(o.m, o.h)
	} else if s.close_issued {
		ws_closed(o.m, o.h, s, WS_ERROR_CLOSE_TIMEOUT)
	}
}

@(private)
ws_clear_timer :: proc(m: ^Ws_Manager, s: ^Socket) {
	if s.timer_data == nil { return }
	host.clear_timer(m.client.loop, s.timer)
	free(s.timer_data)
	s.timer, s.timer_data = base.NIL_HANDLE, nil
}

@(private)
ws_leave_connecting :: proc(m: ^Ws_Manager, s: ^Socket) {
	if !s.counted { return }
	s.counted = false
	if n := m.connecting[s.host_key]; n <= 1 {
		k, _ := delete_key(&m.connecting, s.host_key)
		delete(k, heap())
	} else {
		m.connecting[s.host_key] = n - 1
	}
}

@(private)
ws_job_unref :: proc(job: ^Ws_Job) {
	if sync.atomic_sub(&job.refs, 1) == 1 { ws_free_job(job) }
}

@(private)
ws_free_job :: proc(job: ^Ws_Job) {
	a := heap()
	delete(job.host_w, a); delete(job.target_w, a); delete(job.headers_w, a)
	delete(job.recv, a); delete(job.send_buf, a)
	sync.atomic_sub(&job.mgr.live_jobs, 1)
	free(job, a)
}

// Removes the socket and closes its handles. The only place that closes them.
@(private)
ws_release :: proc(m: ^Ws_Manager, h: base.Handle) -> bool {
	s, ok := base.pool_remove(&m.sockets, h)
	if !ok { return false }
	if s.timer_data != nil { host.clear_timer(m.client.loop, s.timer); free(s.timer_data) }
	if s.job != nil {
		// read before closing: once a handle closes, its HANDLE_CLOSING may free the job on another thread
		handed := sync.atomic_load(&s.job.refs) > 0
		if !handed { ws_free_job(s.job) }
	}
	if s.hws != nil { WinHttpCloseHandle(s.hws) }
	if s.hrequest != nil { WinHttpCloseHandle(s.hrequest) }
	if s.hconnect != nil { WinHttpCloseHandle(s.hconnect) }
	freed_slot := s.counted
	ws_leave_connecting(m, &s)
	delete(s.host_key, heap())
	delete(s.peer_reason, heap())
	for o in s.out { delete(o.data, heap()) }
	delete(s.out)
	delete(s.msg)
	if s.scope != nil { base.run_cleanup(s.scope, s.cleanup) }
	if s.free_user != nil { s.free_user(s.user) }
	if freed_slot { ws_pump(m) }
	return true
}

@(private)
ws_deliver :: proc(s: ^Socket, ev: ^Ws_Event) {
	if s.on_event != nil { s.on_event(s.user, ev.sock, ev) }
}

@(private)
ws_fail :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket, code: u32, flags: u32 = 0) {
	ev := Ws_Event{kind = .Failed, sock = h, error = code, secure_flags = flags}
	ws_deliver(s, &ev)
	ws_release(m, h)
}

// Terminal Closed. Clean as soon as the peer's close frame was read (RFC 6455 §7.1.4 / the WebSocket standard: the
// handshake is complete once a close frame went each way, and whatever happens to the transport afterwards, such as the
// server cutting TCP before our frame's completion was reported, no longer matters). Otherwise 1006.
@(private)
ws_closed :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket, error: u32) {
	ev := Ws_Event{kind = .Closed, sock = h, code = 1006, error = error}
	if s.peer_closed {
		ev.code = s.peer_code == 0 ? WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS : s.peer_code
		ev.reason, ev.clean, ev.error = s.peer_reason, true, 0
	}
	ws_deliver(s, &ev)
	ws_release(m, h)
}

@(private)
ws_pump_send :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) {
	if s.sending || s.hws == nil || !(s.state == .Open || s.state == .Closing) || s.close_issued { return }
	job := s.job
	if !s.has_cur {
		if len(s.out) == 0 { return }
		msg := s.out[0]
		ordered_remove(&s.out, 0)
		job.send_buf = msg.data   // nil for an empty message: still one frame
		s.cur_binary = msg.binary
		s.send_off = 0
		s.has_cur = true
	}
	buf := job.send_buf
	rest := len(buf) - s.send_off
	n := min(rest, s.limits.send_fragment)
	if n < rest && !s.cur_binary {
		// keep each text frame a whole number of characters
		k := n
		for k > 0 && buf[s.send_off + k] & 0xC0 == 0x80 { k -= 1 }
		if k > 0 { n = k }
	}
	last := n == rest
	t: Web_Socket_Buffer_Type
	if s.cur_binary { t = last ? .Binary_Message : .Binary_Fragment } else { t = last ? .Utf8_Message : .Utf8_Fragment }
	ptr: rawptr = n > 0 ? &buf[s.send_off] : nil
	s.sending = true
	s.send_len = n
	if err := WinHttpWebSocketSend(s.hws, t, ptr, win.DWORD(n)); err != 0 && err != ERROR_IO_PENDING {
		s.sending = false
		ws_push(m, Raw{kind = .Error, sock = h, error = err, op = .Send})
	}
}

// Issues our close frame once nothing is being sent (WinHTTP refuses a shutdown while a send is pending). The receive
// stays armed: it reads the peer's close frame. 1005 is WinHTTP's "no status": the frame goes out empty.
@(private)
ws_try_close :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) {
	if s.close_issued || s.sending || s.hws == nil { return }
	if s.close_wanted && (len(s.out) > 0 || s.has_cur) { return }
	s.close_issued = true
	if s.limits.close_timeout_ms > 0 {
		ws_clear_timer(m, s)
		s.timer_data = new_clone(Ws_Owner{m, h})
		s.timer = host.set_timer(m.client.loop, f64(s.limits.close_timeout_ms), 0, ws_timeout, s.timer_data)
	}
	job := s.job
	reason: rawptr = s.close_len > 0 ? &job.close_reason[0] : nil
	if err := WinHttpWebSocketShutdown(s.hws, s.close_code, reason, win.DWORD(s.close_len)); err != 0 && err != ERROR_IO_PENDING {
		ws_push(m, Raw{kind = .Error, sock = h, error = err, op = .Shutdown})
	}
}

// The closing handshake is over once our frame left and the peer's arrived.
@(private)
ws_close_progress :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) {
	if s.close_sent && s.peer_closed { ws_closed(m, h, s, 0) }
}

@(private)
raw_free :: proc(r: ^Raw) {
	a := heap()
	delete(r.headers, a)
	delete(r.data, a)
	delete(r.reason, a)
	r^ = {}
}

@(private)
ws_push :: proc(m: ^Ws_Manager, r: Raw) {
	r := r
	sync.mutex_lock(&m.mu)
	if m.shutting_down {
		sync.mutex_unlock(&m.mu)
		raw_free(&r)
		return
	}
	append(&m.events, r)
	post := !m.drain_pending
	m.drain_pending = true
	sync.mutex_unlock(&m.mu)
	if post { host.post(m.client.loop, ws_drain, m) }
}

@(private)
ws_drain :: proc(data: rawptr) {
	m := (^Ws_Manager)(data)
	sync.mutex_lock(&m.mu)
	m.drain_pending = false
	m.events, m.scratch = m.scratch, m.events
	done := m.shutting_down
	orphaned := m.orphaned
	sync.mutex_unlock(&m.mu)
	for &r in m.scratch {
		if !done { ws_handle(m, &r) }
		raw_free(&r)
	}
	clear(&m.scratch)
	if orphaned {
		// the client was destroyed while this drain was posted
		delete(m.events)
		delete(m.scratch)
		free(m, heap())
	}
}

@(private)
ws_handle :: proc(m: ^Ws_Manager, r: ^Raw) {
	h := r.sock
	s := base.pool_get(&m.sockets, h)
	if s == nil { return }   // aborted: the job may be gone, never look at it
	switch r.kind {
	case .Headers:
		if s.state != .Connecting { return }
		s.state = .Handshake
		ev := Ws_Event{kind = .Handshake, sock = h, status = r.status, headers = r.headers}
		ws_deliver(s, &ev)

	case .Handshake_Failed:
		if s.state == .Open || s.state == .Closing { return }
		ws_fail(m, h, s, r.error, r.secure_flags)

	case .Fragment:
		job := s.job
		n := len(r.data)
		q := sync.atomic_sub(&job.queued, n) - n
		if q < job.low_water && s.hws != nil {
			if _, resumed := sync.atomic_compare_exchange_strong(&job.paused, true, false); resumed {
				if err := ws_receive(job, s.hws); err != 0 { ws_fail(m, h, s, err); return }
			}
		}
		if !(s.state == .Open || s.state == .Closing) { return }
		binary := r.btype == .Binary_Message || r.btype == .Binary_Fragment
		if !s.msg_open {
			s.msg_open, s.msg_binary = true, binary
		} else if s.msg_binary != binary {
			ws_fail(m, h, s, WS_ERROR_PROTOCOL); return
		}
		if len(s.msg) + n > s.limits.max_message { ws_fail(m, h, s, WS_ERROR_MESSAGE_TOO_BIG); return }
		append(&s.msg, ..r.data)
		if r.btype == .Binary_Fragment || r.btype == .Utf8_Fragment { return }
		if !binary && !utf8.valid_string(string(s.msg[:])) { ws_fail(m, h, s, WS_ERROR_INVALID_UTF8); return }
		ev := Ws_Event{kind = .Message, sock = h, data = s.msg[:], binary = binary}
		ws_deliver(s, &ev)
		if s = base.pool_get(&m.sockets, h); s == nil { return }
		s.msg_open = false
		if cap(s.msg) > 4 * s.limits.receive_chunk { delete(s.msg); s.msg = nil } else { clear(&s.msg) }

	case .Peer_Close:
		was_open := s.state == .Open
		s.state = .Closing
		s.peer_closed, s.peer_code = true, r.code
		s.peer_reason, r.reason = r.reason, ""   // owned by the socket now
		if !s.close_wanted {
			// answer with the peer's code (an empty close frame is answered with 1000)
			s.close_wanted = true
			s.close_code = r.code == WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS || r.code == 0 ? 1000 : r.code
			s.close_len = 0
		}
		// no new message starts after the peer's close frame (the one being sent may finish)
		for o in s.out { delete(o.data, heap()) }
		clear(&s.out)
		if was_open {
			ev := Ws_Event{kind = .Closing, sock = h, code = r.code, reason = s.peer_reason}
			ws_deliver(s, &ev)
			if s = base.pool_get(&m.sockets, h); s == nil { return }
		}
		ws_try_close(m, h, s)
		ws_close_progress(m, h, s)

	case .Write_Done:
		s.sending = false
		s.send_off += s.send_len
		sent := s.send_len
		s.send_len = 0
		job := s.job
		if s.has_cur && s.send_off >= len(job.send_buf) {
			delete(job.send_buf, heap())
			job.send_buf = nil
			s.send_off = 0
			s.has_cur = false
		}
		ev := Ws_Event{kind = .Sent, sock = h, sent = sent}
		ws_deliver(s, &ev)
		if s = base.pool_get(&m.sockets, h); s == nil { return }
		ws_pump_send(m, h, s)
		if s.close_wanted { ws_try_close(m, h, s) }

	case .Shutdown_Done:
		s.close_sent = true
		ws_close_progress(m, h, s)

	case .Error:
		// Once a close frame went either way the end is a close, not a failure: clean after the peer's frame, 1006
		// when our close is out and the transport ends before the peer's frame.
		if s.peer_closed || s.close_issued {
			ws_closed(m, h, s, r.error)
			return
		}
		ws_fail(m, h, s, r.error)
	}
}

////////////////////////////////
// WinHTTP threads

@(private)
ws_receive :: proc(job: ^Ws_Job, hws: HINTERNET) -> u32 {
	err := WinHttpWebSocketReceive(hws, raw_data(job.recv), win.DWORD(len(job.recv)), nil, nil)
	if err == 0 || err == ERROR_IO_PENDING { return 0 }
	return err
}

@(private)
ws_push_job :: proc(job: ^Ws_Job, r: Raw) {
	r := r
	r.sock = job.sock
	ws_push(job.mgr, r)
}

@(private)
ws_query_close :: proc(hws: HINTERNET) -> (code: u16, reason: string) {
	buf: [WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON]u8
	used: win.DWORD
	if WinHttpWebSocketQueryCloseStatus(hws, &code, &buf[0], win.DWORD(len(buf)), &used) != 0 { return WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS, "" }
	return code, strings.clone(string(buf[:min(int(used), len(buf))]), heap())
}

@(private)
ws_status_callback :: proc "system" (h: HINTERNET, ctx: win.DWORD_PTR, status: win.DWORD, info: rawptr, info_len: win.DWORD) {
	if ctx == 0 { return }
	context = runtime.default_context()
	job := (^Ws_Job)(uintptr(ctx))
	is_ws := uintptr(rawptr(h)) == sync.atomic_load(&job.hws)

	switch status {
	case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
		if !WinHttpReceiveResponse(h, nil) { ws_handshake_fail(job, u32(win.GetLastError())) }

	case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
		code: win.DWORD
		size: win.DWORD = size_of(code)
		WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &size, nil)
		ws_push_job(job, Raw{kind = .Headers, status = int(code), headers = query_wide(h, WINHTTP_QUERY_RAW_HEADERS_CRLF)})

	case WINHTTP_CALLBACK_STATUS_SECURE_FAILURE:
		job.secure_flags = u32((^win.DWORD)(info)^)

	case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
		if !is_ws { return }
		st := (^Web_Socket_Status)(info)
		if st.buffer_type == .Close {
			c, reason := ws_query_close(h)
			ws_push_job(job, Raw{kind = .Peer_Close, code = c, reason = reason})
			return
		}
		n := int(st.bytes_transferred)
		data: []byte
		if n > 0 { data = make([]byte, n, heap()); copy(data, job.recv[:n]) }
		ws_push_job(job, Raw{kind = .Fragment, data = data, btype = st.buffer_type})
		if sync.atomic_add(&job.queued, n) + n >= job.high_water {
			sync.atomic_store(&job.paused, true)
			// same race as the HTTP client: whoever wins the b32 continues reading
			if sync.atomic_load(&job.queued) < job.low_water {
				if _, mine := sync.atomic_compare_exchange_strong(&job.paused, true, false); !mine { return }
			} else {
				return
			}
		}
		if err := ws_receive(job, h); err != 0 { ws_push_job(job, Raw{kind = .Error, error = err, op = .Receive}) }

	case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
		if !is_ws { return }
		ws_push_job(job, Raw{kind = .Write_Done, n = int((^Web_Socket_Status)(info).bytes_transferred)})

	case WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE:
		if is_ws { ws_push_job(job, Raw{kind = .Shutdown_Done}) }

	case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
		if is_ws {
			ar := (^Web_Socket_Async_Result)(info)
			ws_push_job(job, Raw{kind = .Error, error = u32(ar.result.error), op = ar.operation})
		} else {
			ws_handshake_fail(job, u32((^Async_Result)(info).error))
		}

	case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
		ws_job_unref(job)
	}
}

@(private)
ws_handshake_fail :: proc(job: ^Ws_Job, code: u32) {
	if _, first := sync.atomic_compare_exchange_strong(&job.terminal, false, true); !first { return }
	ws_push_job(job, Raw{kind = .Handshake_Failed, error = code, secure_flags = job.secure_flags})
}
