#+build linux
package remote

// TCP server for the CDP / WebDriver BiDi adapter (src/browser/cdp.odin) on Linux: one accept thread and one
// reader-writer thread per client, waking the event loop with host.post exactly as the Unix socket server
// (server_linux.odin) and the Windows TCP server (tcp_server_windows.odin) do.
//
// It binds loopback only (127.0.0.1, plus best-effort ::1 on the same port with IPV6_V6ONLY): a remote machine cannot
// reach it. Idle threads wait in the kernel via poll(2) + eventfd(2) and consume no CPU.

import "core:sync"
import "core:sys/linux"
import "core:thread"
import "wb:base"
import "wb:host"

Tcp_Handler  :: proc(user: rawptr, conn: u64, data: []byte)   // the loop thread; `data` is valid during the call
Tcp_On_Close :: proc(user: rawptr, conn: u64)                 // the loop thread: the client has gone

@(private = "file") IPV6_LEVEL  :: 41   // IPPROTO_IPV6
@(private = "file") IPV6_V6ONLY :: 26

@(private)
Tcp_Conn :: struct {
	id:      u64,
	sock:    linux.Fd,
	wake_ev: linux.Fd,             // eventfd: outbox has bytes, or the loop asked to close
	thread:  ^thread.Thread,
	inbox:   [dynamic][]byte,      // bytes read, not yet handed out (guarded by t_srv.mu; process heap)
	outbox:  [dynamic][]byte,      // bytes to write (guarded by t_srv.mu; process heap)
	done:    bool,
	closing: bool,                 // the loop asked for the end after the outbox is written
}

@(private)
Tcp_Server :: struct {
	running:     bool,
	mu:          sync.Mutex,
	conns:       [dynamic]^Tcp_Conn,
	loop:        ^host.Loop,
	handler:     Tcp_Handler,
	on_close:    Tcp_On_Close,
	user:        rawptr,
	listener:    linux.Fd,         // 127.0.0.1
	listener6:   linux.Fd,         // ::1 (-1 when IPv6 loopback is unavailable)
	stop_ev:     linux.Fd,         // eventfd, written once: every thread sees it readable from then on
	port:        int,
	next_id:     u64,
	active:      int,              // clients with a thread (atomic)
	max_clients: int,
	client_hold: proc(),           // what a client's thread does first (nil: nothing; a test holds it)
	accept:      ^thread.Thread,
}

@(private) t_srv: Tcp_Server

tcp_running :: proc() -> bool { return t_srv.running }
tcp_port :: proc() -> int { return t_srv.port }

tcp_client_count :: proc() -> int {
	sync.mutex_lock(&t_srv.mu)
	defer sync.mutex_unlock(&t_srv.mu)
	return len(t_srv.conns)
}

// Binds 127.0.0.1 (and best-effort ::1) on `port` (0: an ephemeral port the system picks, read with tcp_port) and
// starts listening. On failure `err` says why (no server then).
tcp_start :: proc(loop: ^host.Loop, port, max_clients: int, handler: Tcp_Handler, on_close: Tcp_On_Close, user: rawptr) -> (err: string) {
	if t_srv.running { return "the CDP channel is already running" }
	if port < 0 || port > 65535 { return "invalid port for the CDP channel" }
	s, serr := linux.socket(.INET, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP)
	if serr != .NONE { return "cannot create the listening socket" }
	one := i32(1)
	_ = linux.setsockopt(s, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one)
	addr := linux.Sock_Addr_In{sin_family = .INET, sin_port = u16be(u16(port)), sin_addr = {127, 0, 0, 1}}
	if linux.bind(s, &addr) != .NONE {
		linux.close(s)
		return "cannot bind 127.0.0.1 (the port may be taken)"
	}
	if linux.listen(s, 128) != .NONE {
		linux.close(s)
		return "cannot listen"
	}
	bound_port := port
	bound: linux.Sock_Addr_Any
	if linux.getsockname(s, &bound) == .NONE { bound_port = int(u16(bound.ipv4.sin_port)) }

	// Best-effort IPv6 loopback listener on the same port so clients connecting via localhost -> ::1 also work.
	s6 := linux.Fd(-1)
	if fd6, err6 := linux.socket(.INET6, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP); err6 == .NONE {
		_ = linux.setsockopt(fd6, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one)
		if linux.setsockopt(fd6, IPV6_LEVEL, IPV6_V6ONLY, &one) == .NONE {
			addr6 := linux.Sock_Addr_In6{sin6_family = .INET6, sin6_port = u16be(u16(bound_port))}
			addr6.sin6_addr[15] = 1   // ::1
			if linux.bind(fd6, &addr6) == .NONE && linux.listen(fd6, 128) == .NONE {
				s6 = fd6
			} else {
				linux.close(fd6)
			}
		} else {
			linux.close(fd6)
		}
	}

	stop_ev, eerr := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if eerr != .NONE {
		linux.close(s)
		if s6 >= 0 { linux.close(s6) }
		return "cannot create the stop event"
	}

	t_srv = {
		loop        = (^host.Loop)(rawptr(loop)),
		handler     = handler,
		on_close    = on_close,
		user        = user,
		listener    = s,
		listener6   = s6,
		stop_ev     = stop_ev,
		port        = bound_port,
		max_clients = max(max_clients, 1),
		conns       = make([dynamic]^Tcp_Conn, base.process_allocator()),
	}
	t_srv.accept = thread.create(tcp_accept_main)
	t_srv.accept.init_context = nil
	thread.start(t_srv.accept)
	t_srv.running = true
	return ""
}

// Stops listening and drops every client. Loop thread.
tcp_stop :: proc() {
	if !t_srv.running { return }
	t_srv.running = false
	host.shutdown_step("cdp_stop: accept thread")
	signal(t_srv.stop_ev)
	if t_srv.accept != nil { thread.join(t_srv.accept); thread.destroy(t_srv.accept); t_srv.accept = nil }
	linux.close(t_srv.listener)
	if t_srv.listener6 >= 0 { linux.close(t_srv.listener6) }
	host.shutdown_step("cdp_stop: client threads")
	sync.mutex_lock(&t_srv.mu)
	conns := t_srv.conns
	t_srv.conns = nil
	for c in conns { signal(c.wake_ev) }
	sync.mutex_unlock(&t_srv.mu)
	for c in conns { tcp_conn_free(c) }
	delete(conns)
	linux.close(t_srv.stop_ev)
	t_srv = {}
}

@(private)
tcp_conn_free :: proc(c: ^Tcp_Conn) {
	if c.thread != nil { thread.join(c.thread); thread.destroy(c.thread) }
	linux.close(c.sock)
	linux.close(c.wake_ev)
	for l in c.inbox { delete(l, base.process_allocator()) }
	for l in c.outbox { delete(l, base.process_allocator()) }
	delete(c.inbox)
	delete(c.outbox)
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
		signal(c.wake_ev)
		return true
	}
	return false
}

// Ends the connection of `id` once what was queued is written.
tcp_close_client :: proc(id: u64) {
	sync.mutex_lock(&t_srv.mu)
	defer sync.mutex_unlock(&t_srv.mu)
	for c in t_srv.conns { if c.id == id { c.closing = true; signal(c.wake_ev) } }
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
tcp_stopped :: proc() -> bool {
	fds := [1]linux.Poll_Fd{{fd = t_srv.stop_ev, events = {.IN}}}
	n, _ := linux.poll(fds[:], 0)
	return n > 0
}

@(private)
tcp_accept_drain :: proc(listen_fd: linux.Fd) -> bool {
	for {
		client, err := linux.accept(listen_fd, cast(^linux.Sock_Addr_Any)nil, {.CLOEXEC, .NONBLOCK})
		if err == .EINTR { continue }
		if err != .NONE { return true }   // EAGAIN: nobody else waiting
		if tcp_stopped() { linux.close(client); return false }
		if !tcp_room_for_client() {
			linux.close(client)   // turned away
			continue
		}
		tcp_start_client(client)
	}
}

@(private)
tcp_accept_main :: proc(_: ^thread.Thread) {
	context = base.process_context()
	for {
		fds: [3]linux.Poll_Fd
		nfds := 0
		fds[nfds] = {fd = t_srv.listener, events = {.IN}}; nfds += 1
		has6 := t_srv.listener6 >= 0
		if has6 { fds[nfds] = {fd = t_srv.listener6, events = {.IN}}; nfds += 1 }
		stop_idx := nfds
		fds[nfds] = {fd = t_srv.stop_ev, events = {.IN}}; nfds += 1
		if !wait(fds[:nfds]) { if tcp_stopped() { return }; continue }
		if fds[stop_idx].revents != {} { return }
		if fds[0].revents != {} {
			if !tcp_accept_drain(t_srv.listener) { return }
		}
		if has6 && fds[1].revents != {} {
			if !tcp_accept_drain(t_srv.listener6) { return }
		}
	}
}

// May one more client come in? At the limit only those still open count: a client's thread may not have seen it close
// yet. A socket closes only after its client has left `t_srv.conns`.
@(private)
tcp_room_for_client :: proc() -> bool {
	if sync.atomic_load(&t_srv.active) < t_srv.max_clients { return true }
	sync.mutex_lock(&t_srv.mu)
	defer sync.mutex_unlock(&t_srv.mu)
	there := 0
	for c in t_srv.conns {
		if c.done { continue }
		b: [1]u8
		n, err := linux.recv(c.sock, b[:], {.PEEK, .DONTWAIT})
		if n > 0 || err == .EAGAIN || err == .EINTR { there += 1 }
	}
	return there < t_srv.max_clients
}

@(private)
tcp_start_client :: proc(sock: linux.Fd) {
	ev, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE { linux.close(sock); return }
	c := new(Tcp_Conn, base.process_allocator())
	c.sock = sock
	c.wake_ev = ev
	c.inbox = make([dynamic][]byte, base.process_allocator())
	c.outbox = make([dynamic][]byte, base.process_allocator())
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
	if t_srv.client_hold != nil { t_srv.client_hold() }
	buf: [16 << 10]byte
	for {
		if !tcp_flush(c) { return }
		sync.mutex_lock(&t_srv.mu)
		closing := c.closing && len(c.outbox) == 0
		sync.mutex_unlock(&t_srv.mu)
		if closing { return }
		fds := [3]linux.Poll_Fd{
			{fd = c.sock, events = {.IN}},
			{fd = c.wake_ev, events = {.IN}},
			{fd = t_srv.stop_ev, events = {.IN}},
		}
		if !wait(fds[:]) { return }
		if fds[2].revents != {} { return }
		if fds[1].revents != {} { drain_event(c.wake_ev) }
		if fds[0].revents != {} {
			for {
				n, err := linux.recv(c.sock, buf[:], {})
				if n > 0 {
					l := make([]byte, n, base.process_allocator())
					copy(l, buf[:n])
					sync.mutex_lock(&t_srv.mu)
					append(&c.inbox, l)
					sync.mutex_unlock(&t_srv.mu)
					tcp_notify()
					continue
				}
				if err == .EINTR { continue }
				if err == .EAGAIN { break }
				return   // peer closed (n == 0) or socket error
			}
		}
	}
}

// Writes everything queued for `c`. False: the socket failed or server stopped (end the client).
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
		n, err := linux.send(c.sock, rest[:min(len(rest), 1 << 20)], {.NOSIGNAL})
		if err == .EINTR { continue }
		if err == .EAGAIN {
			fds := [2]linux.Poll_Fd{{fd = c.sock, events = {.OUT}}, {fd = t_srv.stop_ev, events = {.IN}}}
			if !wait(fds[:]) || fds[1].revents != {} { return false }
			continue
		}
		if err != .NONE || n <= 0 { return false }
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
