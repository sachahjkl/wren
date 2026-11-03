package remote

// The socket server of Linux: the pipe server of server_windows.odin on a Unix socket, the same threads and the same
// contract (server.odin: what they share). Threads that wait in the kernel (poll): one accepts, one per client reads and
// writes. A request line is queued for the interface thread and `host.post` wakes its loop: nothing runs while no client
// sends anything, and nothing exists at all in a process that did not start the channel.
//
//   accept thread  poll(listening socket, stop)  ->  a Conn and its thread
//   client thread  poll(socket, outbox eventfd, stop)  ->  lines into Conn.inbox, replies out of Conn.outbox
//   loop thread    on_input: takes the lines of every client to the handler, forgets the clients that have gone
//
// Only the current user reaches the socket: it lives in a folder of this user's closed to everyone else (socket_dir),
// the socket itself is 0600, and a client whose credentials (SO_PEERCRED) are another user's is closed at once. A socket
// another live process listens on is not taken over (a second server is an error, as FILE_FLAG_FIRST_PIPE_INSTANCE
// makes it on Windows); one left by a process that died is replaced. A request line longer than the limit ends the
// connection, and a page cannot reach the channel.

import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "wb:base"
import "wb:host"

@(private)
Conn_Sys :: struct {
	sock:      linux.Fd,
	out_event: linux.Fd,   // eventfd: the outbox has lines, or the loop asks for the end
}

@(private)
Server_Sys :: struct {
	path:       string,     // the socket's (process heap)
	listen:     linux.Fd,
	stop_event: linux.Fd,   // eventfd, written once: every thread sees it readable from then on
}

// Opens the socket and starts listening. `name` is valid_name. On failure `err` says why (no server then).
start :: proc(loop: ^host.Loop, name: string, max_message, max_clients: int, handler: Handler, on_close: On_Close, user: rawptr) -> (err: string) {
	if srv.running { return "the remote channel is already running" }
	if !valid_name(name) { return "invalid name: use letters, digits, '-', '_' and '.'" }
	dir, safe := socket_dir()
	if !safe { return strings.concatenate({"the folder of the socket (", dir, ") is not this user's alone"}, context.temp_allocator) }
	path := pipe_path(name)
	addr, ok := unix_address(path)
	if !ok { return "the path of the socket is too long" }
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if probe := unix_connect(path); probe >= 0 {
		linux.close(probe)
		return "the socket name is taken by another process"
	}
	linux.unlink(cpath)   // left by a process that died: nobody answered on it
	s, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if serr != .NONE { return "cannot create the socket" }
	if linux.bind(s, &addr) != .NONE { linux.close(s); return "cannot create the socket (bind)" }
	linux.chmod(cpath, {.IRUSR, .IWUSR})
	if linux.listen(s, 64) != .NONE { linux.close(s); linux.unlink(cpath); return "cannot create the socket (listen)" }
	stop_ev, eerr := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if eerr != .NONE { linux.close(s); linux.unlink(cpath); return "cannot create the stop event" }
	srv = {loop = loop, handler = handler, on_close = on_close, user = user, max_message = max_message, max_clients = max_clients}
	srv.path = strings.clone(path, base.process_allocator())
	srv.listen, srv.stop_event = s, stop_ev
	srv.accept = thread.create(accept_main)
	srv.accept.init_context = nil
	thread.start(srv.accept)
	srv.running = true
	return ""
}

@(private)
stop_threads :: proc() { signal(srv.stop_event) }

@(private)
server_close :: proc() {
	linux.close(srv.listen)
	linux.unlink(strings.clone_to_cstring(srv.path, context.temp_allocator))
	linux.close(srv.stop_event)
	delete(srv.path, base.process_allocator())
}

////////////////////////////////
// Sockets and events

@(private)
unix_address :: proc(path: string) -> (addr: linux.Sock_Addr_Un, ok: bool) {
	if len(path) >= len(addr.sun_path) { return {}, false }
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	return addr, true
}

// A blocking connection to the socket at `path`, or -1.
unix_connect :: proc(path: string) -> linux.Fd {
	addr, ok := unix_address(path)
	if !ok { return -1 }
	s, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE { return -1 }
	for {
		e := linux.connect(s, &addr)
		if e == .EINTR { continue }
		if e != .NONE { linux.close(s); return -1 }
		return s
	}
}

@(private)
signal :: proc(ev: linux.Fd) {
	one := u64(1)
	linux.write(ev, ([^]u8)(&one)[:8])
}

@(private)
event_close :: proc(ev: linux.Fd) { linux.close(ev) }

@(private)
drain_event :: proc(ev: linux.Fd) {
	v: u64
	linux.read(ev, ([^]u8)(&v)[:8])
}

// Waits for any of `fds` to be ready (EINTR retried). The ready events of each, in place.
@(private)
wait :: proc(fds: []linux.Poll_Fd) -> bool {
	for {
		n, err := linux.poll(fds, -1)
		if err == .EINTR { continue }
		return err == .NONE && n > 0
	}
}

@(private)
stopped :: proc() -> bool {
	fds := []linux.Poll_Fd{{fd = srv.stop_event, events = {.IN}}}
	n, _ := linux.poll(fds, 0)
	return n > 0
}

// The peer is this user (SO_PEERCRED): the folder already keeps others out, this is the second lock.
@(private)
same_user :: proc(s: linux.Fd) -> bool {
	Ucred :: struct { pid: i32, uid: u32, gid: u32 }
	cred: Ucred
	size := u32(size_of(cred))
	// (the system call itself: core:sys/linux's getsockopt passes the size of the pointer, not of what it points to)
	if linux.syscall(linux.SYS_getsockopt, s, 1 /* SOL_SOCKET */, 17 /* SO_PEERCRED */, &cred, &size) != 0 { return false }
	return size == size_of(cred) && cred.uid == u32(linux.getuid())
}

////////////////////////////////
// Threads

@(private)
accept_main :: proc(_: ^thread.Thread) {
	context = base.process_context()
	for {
		fds := []linux.Poll_Fd{{fd = srv.listen, events = {.IN}}, {fd = srv.stop_event, events = {.IN}}}
		if !wait(fds) { if stopped() { return }; continue }
		if fds[1].revents != {} { return }
		for {
			c, err := linux.accept(srv.listen, cast(^linux.Sock_Addr_Un)nil, {.CLOEXEC, .NONBLOCK})
			if err == .EINTR { continue }
			if err != .NONE { break }   // EAGAIN: nobody else waits
			if !same_user(c) || sync.atomic_load(&srv.active) >= srv.max_clients {
				linux.close(c)   // turned away: the client sees the socket close
				continue
			}
			start_client(c)
		}
	}
}

@(private)
start_client :: proc(s: linux.Fd) {
	ev, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE { linux.close(s); return }
	c := new(Conn, base.process_allocator())
	c.sock, c.out_event = s, ev
	conn_start(c)
}

@(private)
client_main :: proc(t: ^thread.Thread) {
	context = base.process_context()
	c := (^Conn)(t.data)
	defer { linux.close(c.sock); conn_done(c) }
	buf := make([]byte, 64 << 10, base.process_allocator())
	defer delete(buf, base.process_allocator())
	pending := make([dynamic]byte, base.process_allocator())
	defer delete(pending)
	for {
		fds := []linux.Poll_Fd{{fd = c.sock, events = {.IN}}, {fd = c.out_event, events = {.IN}}, {fd = srv.stop_event, events = {.IN}}}
		if !wait(fds) { return }
		if fds[2].revents != {} { return }   // the server stops
		if fds[0].revents != {} {
			n, err := linux.recv(c.sock, buf, {})
			if err == .EINTR || err == .EAGAIN { continue }
			if err != .NONE || n <= 0 { return }   // the client closed
			append(&pending, ..buf[:n])
			if !take_lines(c, &pending) { return }
		}
		if fds[1].revents != {} {
			drain_event(c.out_event)
			if !flush_outbox(c) || conn_closing(c) { return }
		}
	}
}

// Writes all of `data`, waiting for the socket (a client that does not read ends with the server, not before).
@(private)
write_all :: proc(c: ^Conn, data: []byte) -> bool {
	rest := data
	for len(rest) > 0 {
		n, err := linux.send(c.sock, rest[:min(len(rest), 1 << 20)], {.NOSIGNAL})
		if err == .EINTR { continue }
		if err == .EAGAIN {
			fds := []linux.Poll_Fd{{fd = c.sock, events = {.OUT}}, {fd = srv.stop_event, events = {.IN}}}
			if !wait(fds) || fds[1].revents != {} { return false }
			continue
		}
		if err != .NONE || n <= 0 { return false }
		rest = rest[n:]
	}
	return true
}
