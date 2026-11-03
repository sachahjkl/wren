#+build windows, linux
package remote

// What the pipe server (server_windows.odin) and the socket server (server_linux.odin) share: the clients, their
// queues and the loop side. Each system's file gives the connection's and the server's own handles (Conn_Sys,
// Server_Sys), opens and closes them (start, stop_threads, server_close, client_main), and writes (write_all, signal).
//
//   accept thread  a new client  ->  conn_start: a Conn and its thread
//   client thread  lines into Conn.inbox (take_lines), replies out of Conn.outbox (flush_outbox)
//   loop thread    on_input: takes the lines of every client to the handler, forgets the clients that have gone

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "wb:base"
import "wb:host"

Handler  :: proc(user: rawptr, conn: u64, line: []byte)   // the loop thread; `line` is valid during the call
On_Close :: proc(user: rawptr, conn: u64)                 // the loop thread: the client has gone

@(private)
Conn :: struct {
	id:        u64,
	thread:    ^thread.Thread,
	inbox:     [dynamic][]byte,   // lines read, not yet handled (guarded by srv.mu; the process heap)
	outbox:    [dynamic][]byte,   // lines to write, each with its "\n" (guarded by srv.mu)
	done:      bool,              // the thread has finished (guarded by srv.mu)
	closing:   bool,              // the loop asked for the end after the outbox is written (guarded by srv.mu)
	using sys: Conn_Sys,
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
	accept:      ^thread.Thread,
	max_message: int,
	max_clients: int,
	next_id:     u64,
	active:      int,   // clients connected (atomic)
	using sys:   Server_Sys,
}

@(private) srv: Server

running :: proc() -> bool { return srv.running }

client_count :: proc() -> int {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	return len(srv.conns)
}

// Stops listening and drops every client (their threads end, their pipes or sockets close). Loop thread.
stop :: proc() {
	if !srv.running { return }
	srv.running = false
	host.shutdown_step("remote_stop: accept thread")
	stop_threads()
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
	server_close()
	srv = {}
}

@(private)
conn_free :: proc(c: ^Conn) {
	thread.join(c.thread)
	thread.destroy(c.thread)
	for l in c.inbox { delete(l, base.process_allocator()) }
	for l in c.outbox { delete(l, base.process_allocator()) }
	delete(c.inbox); delete(c.outbox)
	event_close(c.out_event)
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
// Threads

// A wake for the loop: the task runs on_input (the data is not used: the server is a global).
@(private)
notify :: proc() { host.post(srv.loop, on_input, nil) }

// Counts `c` (its handles set) among the clients and starts its thread.
@(private)
conn_start :: proc(c: ^Conn) {
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

// The end of a client's thread (its pipe or socket closed): the loop forgets it.
@(private)
conn_done :: proc(c: ^Conn) {
	sync.mutex_lock(&srv.mu)
	c.done = true
	sync.mutex_unlock(&srv.mu)
	sync.atomic_sub(&srv.active, 1)
	notify()
}

// The loop asked for the end and everything queued is written.
@(private)
conn_closing :: proc(c: ^Conn) -> bool {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	return c.closing && len(c.outbox) == 0
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

////////////////////////////////
// Loop side

// The lines that came go to the handler, the clients that went are forgotten. (The loop thread.)
@(private)
on_input :: proc(_: rawptr) {
	if !srv.running { return }
	// This task draws nothing by itself (it is posted for a request, and again for a client that went: a `wren ctl` call is both):
	// the handler asks for the frames a request needs, so that a request that only reads leaves a resting browser at rest
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
		`{"name":`, quote(name), `,"pipe":`, quote(pipe_path(name)), `,"pid":`, fmt.tprint(os.get_pid()),
		`,"protocol":`, fmt.tprint(PROTOCOL_VERSION), `,"version":`, quote(version), `,"profile":`, quote(full_path(profile_dir)), "}\n",
	}, context.temp_allocator)
	return os.write_entire_file(info_path(profile_dir), transmute([]byte)text) == nil
}

remove_info :: proc(profile_dir: string) { _ = os.remove(info_path(profile_dir)) }
