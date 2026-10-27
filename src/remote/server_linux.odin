package remote

// The socket server of Linux: the pipe server of server_windows.odin on a Unix socket, the same threads and the same
// contract. Threads that wait in the kernel (poll): one accepts, one per client reads and writes. A request line is
// queued for the interface thread and `host.post` wakes its loop: nothing runs while no client sends anything, and
// nothing exists at all in a process that did not start the channel.
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

import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "wb:base"
import "wb:host"

Handler  :: proc(user: rawptr, conn: u64, line: []byte)   // the loop thread; `line` is valid during the call
On_Close :: proc(user: rawptr, conn: u64)                 // the loop thread: the client has gone

@(private)
Conn :: struct {
	id:        u64,
	sock:      linux.Fd,
	thread:    ^thread.Thread,
	out_event: linux.Fd,          // eventfd: the outbox has lines, or the loop asks for the end
	inbox:     [dynamic][]byte,   // lines read, not yet handled (guarded by srv.mu; the process heap)
	outbox:    [dynamic][]byte,   // lines to write, each with its "\n" (guarded by srv.mu)
	done:      bool,              // the thread has finished (guarded by srv.mu)
	closing:   bool,              // the loop asked for the end after the outbox is written (guarded by srv.mu)
}

@(private)
Server :: struct {
	running:     bool,
	mu:          sync.Mutex,
	conns:       [dynamic]^Conn,
	loop:        ^host.Loop,
	handler:     Handler,
	on_close:    On_Close,
	user:        rawptr,
	path:        string,       // the socket's (process heap)
	listen:      linux.Fd,
	stop_event:  linux.Fd,     // eventfd, written once: every thread sees it readable from then on
	accept:      ^thread.Thread,
	max_message: int,
	max_clients: int,
	next_id:     u64,
	active:      int,   // clients connected (atomic)
}

@(private) srv: Server

running :: proc() -> bool { return srv.running }

client_count :: proc() -> int {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	return len(srv.conns)
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

// Stops listening and drops every client (their threads end, their sockets close). Loop thread.
stop :: proc() {
	if !srv.running { return }
	srv.running = false
	host.shutdown_step("remote_stop: accept thread")
	signal(srv.stop_event)
	thread.join(srv.accept)
	thread.destroy(srv.accept)
	host.shutdown_step("remote_stop: client threads")
	sync.mutex_lock(&srv.mu)
	conns := srv.conns
	srv.conns = nil
	sync.mutex_unlock(&srv.mu)
	for c in conns { conn_free(c) }
	host.shutdown_step("remote_stop: files")
	delete(conns)
	linux.close(srv.listen)
	linux.unlink(strings.clone_to_cstring(srv.path, context.temp_allocator))
	linux.close(srv.stop_event)
	delete(srv.path, base.process_allocator())
	srv = {}
}

@(private)
conn_free :: proc(c: ^Conn) {
	thread.join(c.thread)
	thread.destroy(c.thread)
	for l in c.inbox { delete(l, base.process_allocator()) }
	for l in c.outbox { delete(l, base.process_allocator()) }
	delete(c.inbox); delete(c.outbox)
	linux.close(c.out_event)
	free(c, base.process_allocator())
}

// Queues `line` (JSON, no newline) for client `id`. False when that client is gone. Loop thread.
send :: proc(id: u64, line: string) -> bool {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	for c in srv.conns {
		if c.id != id || c.done { continue }
		out := make([]byte, len(line) + 1, base.process_allocator())
		copy(out, line)
		out[len(line)] = '\n'
		append(&c.outbox, out)
		signal(c.out_event)
		return true
	}
	return false
}

// Ends the connection of `id` once what was queued for it has been written.
close_client :: proc(id: u64) {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	for c in srv.conns {
		if c.id == id { c.closing = true; signal(c.out_event) }
	}
}

// The ids of the clients connected now.
client_ids :: proc(allocator := context.temp_allocator) -> []u64 {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	ids := make([dynamic]u64, allocator)
	for c in srv.conns { if !c.done { append(&ids, c.id) } }
	return ids[:]
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

// A wake for the loop: the task runs on_input (the data is not used: the server is a global).
@(private)
notify :: proc() { host.post(srv.loop, on_input, nil) }

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
	sync.mutex_lock(&srv.mu)
	srv.next_id += 1
	c.id = srv.next_id
	append(&srv.conns, c)
	sync.mutex_unlock(&srv.mu)
	sync.atomic_add(&srv.active, 1)
	c.thread = thread.create(client_main)
	c.thread.data = c
	c.thread.init_context = nil
	thread.start(c.thread)
}

@(private)
client_main :: proc(t: ^thread.Thread) {
	context = base.process_context()
	c := (^Conn)(t.data)
	defer {
		linux.close(c.sock)
		sync.mutex_lock(&srv.mu)
		c.done = true
		sync.mutex_unlock(&srv.mu)
		sync.atomic_sub(&srv.active, 1)
		notify()
	}
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
			if !flush_outbox(c) { return }
			sync.mutex_lock(&srv.mu)
			closing := c.closing && len(c.outbox) == 0
			sync.mutex_unlock(&srv.mu)
			if closing { return }
		}
	}
}

// Moves the complete lines of `pending` to the inbox. False: a line is longer than the limit (answered, then the end).
@(private)
take_lines :: proc(c: ^Conn, pending: ^[dynamic]byte) -> bool {
	got := false
	for {
		nl := -1
		for b, i in pending^ { if b == '\n' { nl = i; break } }
		if nl < 0 { break }
		line := pending[:nl]
		if nl > 0 && line[nl - 1] == '\r' { line = line[:nl - 1] }
		if len(line) > srv.max_message { too_long(c); return false }
		if len(line) > 0 {
			l := make([]byte, len(line), base.process_allocator())
			copy(l, line)
			sync.mutex_lock(&srv.mu)
			append(&c.inbox, l)
			sync.mutex_unlock(&srv.mu)
			got = true
		}
		remove_range(pending, 0, nl + 1)
	}
	if len(pending) > srv.max_message { too_long(c); return false }
	if got { notify() }
	return true
}

@(private)
too_long :: proc(c: ^Conn) {
	msg := transmute([]byte)string(`{"id":null,"error":{"code":-32600,"message":"request line longer than browser.remote.max_message_bytes"}}` + "\n")
	write_all(c, msg)
}

@(private)
flush_outbox :: proc(c: ^Conn) -> bool {
	for {
		sync.mutex_lock(&srv.mu)
		if len(c.outbox) == 0 { sync.mutex_unlock(&srv.mu); return true }
		line := c.outbox[0]
		ordered_remove(&c.outbox, 0)
		sync.mutex_unlock(&srv.mu)
		ok := write_all(c, line)
		delete(line, base.process_allocator())
		if !ok { return false }
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

////////////////////////////////
// Loop side

// The lines that came go to the handler, the clients that went are forgotten. (The loop thread.)
@(private)
on_input :: proc(_: rawptr) {
	if !srv.running { return }
	// (see server_windows.odin: a request that only reads leaves a resting browser at rest)
	host.quiet_note(srv.loop)
	for {
		line: []byte
		id: u64
		sync.mutex_lock(&srv.mu)
		for c in srv.conns {
			if len(c.inbox) > 0 { line, id = c.inbox[0], c.id; ordered_remove(&c.inbox, 0); break }
		}
		sync.mutex_unlock(&srv.mu)
		if line == nil { break }
		srv.handler(srv.user, id, line)
		delete(line, base.process_allocator())
		if !srv.running { return }   // (the handler stopped the channel)
	}
	for {
		gone: ^Conn
		sync.mutex_lock(&srv.mu)
		for c, i in srv.conns {
			if c.done && len(c.inbox) == 0 { gone = c; unordered_remove(&srv.conns, i); break }
		}
		sync.mutex_unlock(&srv.mu)
		if gone == nil { break }
		id := gone.id
		conn_free(gone)
		if srv.on_close != nil { srv.on_close(srv.user, id) }
	}
}

////////////////////////////////
// The profile's files

// <profile>/remote.json: what a client reads to find this instance.
write_info :: proc(profile_dir, name, version: string) -> bool {
	text := strings.concatenate({
		`{"name":`, quote(name), `,"pipe":`, quote(pipe_path(name)), `,"pid":`, itoa(os.get_pid()),
		`,"protocol":`, itoa(PROTOCOL_VERSION), `,"version":`, quote(version), `,"profile":`, quote(full_path(profile_dir)), "}\n",
	}, context.temp_allocator)
	return os.write_entire_file(info_path(profile_dir), transmute([]byte)text) == nil
}

remove_info :: proc(profile_dir: string) { _ = os.remove(info_path(profile_dir)) }

@(private)
itoa :: proc(n: int) -> string {
	buf: [24]byte
	i := len(buf)
	v := n
	neg := v < 0
	if neg { v = -v }
	for { i -= 1; buf[i] = byte('0' + v % 10); v /= 10; if v == 0 { break } }
	if neg { i -= 1; buf[i] = '-' }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}
