#+build windows
package remote

// A tiny TCP server for the CDP / WebDriver BiDi adapter (src/browser/cdp.odin): one accept thread and one
// reader-writer thread per client, waking the event loop with host.post exactly as the pipe server does. It carries
// raw bytes; the adapter does the HTTP and WebSocket handling (ws.odin) on the loop thread. Raw Winsock
// (core:sys/windows), not core:net, so the package name `net` does not clash with Wren's own src/net.
//
// It binds the loopback address only (127.0.0.1): a remote machine cannot reach it. A DNS-rebinding guard (Host and
// Origin must be loopback) is the adapter's, on the handshake. The channel is off unless asked for (remote.cdp.enabled
// or --remote-debugging-port); nothing of it exists in a process that did not start it. Sockets are watched with
// WSAEventSelect / WaitForMultipleObjects, so an idle server uses no CPU.

import "base:runtime"
import "core:sync"
import "core:thread"
import win "core:sys/windows"
import "wb:base"
import "wb:host"

Tcp_Handler  :: proc(user: rawptr, conn: u64, data: []byte)   // the loop thread; `data` is valid during the call
Tcp_On_Close :: proc(user: rawptr, conn: u64)                 // the loop thread: the client has gone

FD_READ   :: 0x01
FD_ACCEPT :: 0x08
FD_CLOSE  :: 0x20

@(private)
Tcp_Conn :: struct {
	id:      u64,
	sock:    win.SOCKET,
	thread:  ^thread.Thread,
	net_ev:  win.WSAEVENT,         // signaled on FD_READ / FD_CLOSE
	wake:    win.HANDLE,           // the writer wakes on it (an item queued, or the end asked)
	inbox:   [dynamic][]byte,      // bytes read, not yet handed out (guarded by t_srv.mu; the process heap)
	outbox:  [dynamic][]byte,      // bytes to write (guarded by t_srv.mu)
	done:    bool,
	closing: bool,                 // the loop asked for the end after the outbox is written
}

@(private)
Tcp_Server :: struct {
	running:   bool,
	mu:        sync.Mutex,
	conns:     [dynamic]^Tcp_Conn,
	loop:      ^host.Loop,
	handler:   Tcp_Handler,
	on_close:  Tcp_On_Close,
	user:      rawptr,
	listener:  win.SOCKET,
	accept_ev: win.WSAEVENT,
	stop_ev:   win.HANDLE,         // the accept and client threads wake on it and end
	port:      int,
	next_id:   u64,
	active:    int,                // clients connected (atomic)
	max_clients: int,
	accept:    ^thread.Thread,
}

@(private) t_srv: Tcp_Server

tcp_running :: proc() -> bool { return t_srv.running }
tcp_port :: proc() -> int { return t_srv.port }

tcp_client_count :: proc() -> int {
	sync.mutex_lock(&t_srv.mu)
	defer sync.mutex_unlock(&t_srv.mu)
	return len(t_srv.conns)
}

// Binds 127.0.0.1 on `port` (0: an ephemeral port the system picks, read with tcp_port) and starts listening. On
// failure `err` says why (no server then).
tcp_start :: proc(loop: ^host.Loop, port, max_clients: int, handler: Tcp_Handler, on_close: Tcp_On_Close, user: rawptr) -> (err: string) {
	if t_srv.running { return "the CDP channel is already running" }
	wsadata: win.WSADATA
	win.WSAStartup(0x0202, &wsadata)   // idempotent: core already starts Winsock elsewhere, a second call is reference-counted
	t_srv = {loop = loop, handler = handler, on_close = on_close, user = user, max_clients = max(max_clients, 1)}
	s := win.socket(win.AF_INET, win.SOCK_STREAM, win.IPPROTO_TCP)
	if s == win.INVALID_SOCKET { t_srv = {}; return "cannot create the listening socket" }
	addr := win.sockaddr_in{sin_family = u16(win.AF_INET), sin_port = u16be(u16(port)), sin_addr = {s_addr = tcp_loopback_be()}}
	if win.bind(s, cast(^win.SOCKADDR_STORAGE_LH)&addr, size_of(addr)) == win.SOCKET_ERROR {
		win.closesocket(s); t_srv = {}
		return "cannot bind 127.0.0.1 (the port may be taken)"
	}
	if win.listen(s, win.SOMAXCONN) == win.SOCKET_ERROR { win.closesocket(s); t_srv = {}; return "cannot listen" }
	// the port the system gave (when 0 was asked): read it back
	bound := win.sockaddr_in{}
	blen := i32(size_of(bound))
	if win.getsockname(s, cast(^win.SOCKADDR_STORAGE_LH)&bound, &blen) == 0 {
		t_srv.port = int(u16(bound.sin_port))
	} else {
		t_srv.port = port
	}
	t_srv.listener = s
	t_srv.stop_ev = win.CreateEventW(nil, true, false, nil)   // manual-reset: every thread sees the stop
	t_srv.accept_ev = win.WSACreateEvent()
	win.WSAEventSelect(s, t_srv.accept_ev, FD_ACCEPT)
	t_srv.accept = thread.create(tcp_accept_main)
	t_srv.accept.init_context = nil
	thread.start(t_srv.accept)
	t_srv.running = true
	return ""
}

@(private)
tcp_loopback_be :: proc() -> u32 { return 0x0100007f }   // 127.0.0.1 in network byte order (the in_addr is raw bytes)

// Stops listening and drops every client. Loop thread.
tcp_stop :: proc() {
	if !t_srv.running { return }
	t_srv.running = false
	host.shutdown_step("cdp_stop: accept thread")
	win.SetEvent(t_srv.stop_ev)
	if t_srv.accept != nil { thread.join(t_srv.accept); thread.destroy(t_srv.accept); t_srv.accept = nil }
	win.closesocket(t_srv.listener)
	if t_srv.accept_ev != nil { win.WSACloseEvent(t_srv.accept_ev) }
	host.shutdown_step("cdp_stop: client threads")
	sync.mutex_lock(&t_srv.mu)
	conns := t_srv.conns
	t_srv.conns = nil
	for c in conns { if c.wake != nil { win.SetEvent(c.wake) } }
	sync.mutex_unlock(&t_srv.mu)
	for c in conns { tcp_conn_free(c) }
	delete(conns)
	win.CloseHandle(t_srv.stop_ev)
	t_srv = {}
}

@(private)
tcp_conn_free :: proc(c: ^Tcp_Conn) {
	if c.thread != nil { thread.join(c.thread); thread.destroy(c.thread) }
	win.closesocket(c.sock)
	if c.net_ev != nil { win.WSACloseEvent(c.net_ev) }
	if c.wake != nil { win.CloseHandle(c.wake) }
	for l in c.inbox { delete(l, base.process_allocator()) }
	for l in c.outbox { delete(l, base.process_allocator()) }
	delete(c.inbox); delete(c.outbox)
	free(c, base.process_allocator())
}

// Queues `data` (bytes, a whole WebSocket frame or an HTTP response) for client `id`. False when it is gone. Loop thread.
tcp_send :: proc(id: u64, data: []byte) -> bool {
	sync.mutex_lock(&t_srv.mu)
	defer sync.mutex_unlock(&t_srv.mu)
	for c in t_srv.conns {
		if c.id != id || c.done { continue }
		out := make([]byte, len(data), base.process_allocator())
		copy(out, data)
		append(&c.outbox, out)
		if c.wake != nil { win.SetEvent(c.wake) }
		return true
	}
	return false
}

// Ends the connection of `id` once what was queued is written.
tcp_close_client :: proc(id: u64) {
	sync.mutex_lock(&t_srv.mu)
	defer sync.mutex_unlock(&t_srv.mu)
	for c in t_srv.conns { if c.id == id { c.closing = true; if c.wake != nil { win.SetEvent(c.wake) } } }
}

tcp_client_ids :: proc(allocator := context.temp_allocator) -> []u64 {
	sync.mutex_lock(&t_srv.mu)
	defer sync.mutex_unlock(&t_srv.mu)
	ids := make([dynamic]u64, allocator)
	for c in t_srv.conns { if !c.done { append(&ids, c.id) } }
	return ids[:]
}

////////////////////////////////
// Threads

@(private)
tcp_notify :: proc() { host.post(t_srv.loop, tcp_on_input, nil) }

@(private)
tcp_accept_main :: proc(_: ^thread.Thread) {
	context = base.process_context()
	handles := [2]win.HANDLE{win.HANDLE(t_srv.accept_ev), t_srv.stop_ev}
	for {
		w := win.WaitForMultipleObjects(2, &handles[0], false, win.INFINITE)
		if w != win.WAIT_OBJECT_0 { return }   // the stop event, or a wait failure
		win.ResetEvent(win.HANDLE(t_srv.accept_ev))
		for {   // drain every pending accept (the event is level-triggered once per FD_ACCEPT)
			client := win.accept(t_srv.listener, nil, nil)
			if client == win.INVALID_SOCKET { break }
			if win.WaitForSingleObject(t_srv.stop_ev, 0) == win.WAIT_OBJECT_0 { win.closesocket(client); return }
			if sync.atomic_load(&t_srv.active) >= t_srv.max_clients {
				win.closesocket(client)   // turned away
				continue
			}
			tcp_start_client(client)
		}
	}
}

@(private)
tcp_start_client :: proc(sock: win.SOCKET) {
	c := new(Tcp_Conn, base.process_allocator())
	c.sock = sock
	c.net_ev = win.WSACreateEvent()
	c.wake = win.CreateEventW(nil, false, false, nil)
	win.WSAEventSelect(sock, c.net_ev, FD_READ | FD_CLOSE)   // also makes the socket non-blocking
	sync.mutex_lock(&t_srv.mu)
	t_srv.next_id += 1
	c.id = t_srv.next_id
	append(&t_srv.conns, c)
	sync.mutex_unlock(&t_srv.mu)
	sync.atomic_add(&t_srv.active, 1)
	c.thread = thread.create(tcp_client_main)
	c.thread.data = c
	c.thread.init_context = nil
	thread.start(c.thread)
}

@(private)
tcp_client_main :: proc(t: ^thread.Thread) {
	context = base.process_context()
	c := (^Tcp_Conn)(t.data)
	defer {
		sync.mutex_lock(&t_srv.mu)
		c.done = true
		sync.mutex_unlock(&t_srv.mu)
		sync.atomic_sub(&t_srv.active, 1)
		tcp_notify()
	}
	buf: [16 << 10]byte
	handles := [3]win.HANDLE{win.HANDLE(c.net_ev), c.wake, t_srv.stop_ev}
	for {
		if !tcp_flush(c) { return }
		sync.mutex_lock(&t_srv.mu)
		closing := c.closing && len(c.outbox) == 0
		sync.mutex_unlock(&t_srv.mu)
		if closing { return }
		w := win.WaitForMultipleObjects(3, &handles[0], false, win.INFINITE)
		switch w {
		case win.WAIT_OBJECT_0:   // readable, or closed
			win.ResetEvent(win.HANDLE(c.net_ev))
			for {
				n := win.recv(c.sock, &buf[0], i32(len(buf)), 0)
				if n > 0 {
					l := make([]byte, int(n), base.process_allocator())
					copy(l, buf[:n])
					sync.mutex_lock(&t_srv.mu)
					append(&c.inbox, l)
					sync.mutex_unlock(&t_srv.mu)
					tcp_notify()
					continue
				}
				if n == 0 { return }   // the peer closed
				if win.WSAGetLastError() == win.WSAEWOULDBLOCK { break }   // drained for now
				return
			}
		case win.WAIT_OBJECT_0 + 1:   // the wake: an item queued or the end asked
		case:
			return   // the server stops
		}
	}
}

// Writes everything queued for `c`. False: the socket failed (end the client).
@(private)
tcp_flush :: proc(c: ^Tcp_Conn) -> bool {
	for {
		sync.mutex_lock(&t_srv.mu)
		if len(c.outbox) == 0 { sync.mutex_unlock(&t_srv.mu); return true }
		data := c.outbox[0]
		ordered_remove(&c.outbox, 0)
		sync.mutex_unlock(&t_srv.mu)
		ok := tcp_write_all(c, data)
		delete(data, base.process_allocator())
		if !ok { return false }
	}
}

@(private)
tcp_write_all :: proc(c: ^Tcp_Conn, data: []byte) -> bool {
	rest := data
	for len(rest) > 0 {
		n := win.send(c.sock, raw_data(rest), i32(len(rest)), 0)
		if n == win.SOCKET_ERROR {
			if win.WSAGetLastError() == win.WSAEWOULDBLOCK { win.Sleep(1); continue }   // the send buffer is full
			return false
		}
		if n <= 0 { return false }
		rest = rest[n:]
	}
	return true
}

////////////////////////////////
// Loop side

@(private)
tcp_on_input :: proc(_: rawptr) {
	if !t_srv.running { return }
	host.quiet_note(t_srv.loop)   // the carrier task draws nothing by itself; the handler asks for frames a command needs
	for {
		data: []byte
		id: u64
		sync.mutex_lock(&t_srv.mu)
		for c in t_srv.conns {
			if len(c.inbox) > 0 { data, id = c.inbox[0], c.id; ordered_remove(&c.inbox, 0); break }
		}
		sync.mutex_unlock(&t_srv.mu)
		if data == nil { break }
		t_srv.handler(t_srv.user, id, data)
		delete(data, base.process_allocator())
		if !t_srv.running { return }
	}
	for {
		gone: ^Tcp_Conn
		sync.mutex_lock(&t_srv.mu)
		for c, i in t_srv.conns {
			if c.done && len(c.inbox) == 0 { gone = c; unordered_remove(&t_srv.conns, i); break }
		}
		sync.mutex_unlock(&t_srv.mu)
		if gone == nil { break }
		id := gone.id
		tcp_conn_free(gone)
		if t_srv.on_close != nil { t_srv.on_close(t_srv.user, id) }
	}
}

_ :: runtime
