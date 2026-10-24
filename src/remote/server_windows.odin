#+build windows
package remote

// The pipe server. Overlapped I/O on threads that wait in the kernel: one accepts, one per client reads and writes. A
// request line is queued for the interface thread and `host.post` wakes its loop: no timer, no polling, nothing runs while no
// client sends anything, and nothing exists at all in a process that did not start the channel.
//
//   accept thread  ConnectNamedPipe (overlapped) / stop event  ->  a Conn and its thread
//   client thread  ReadFile (overlapped) / outbox event / stop event  ->  lines into Conn.inbox, replies out of Conn.outbox
//   loop thread    on_input: takes the lines of every client to the handler, forgets the clients that have gone
//
// Only the current user can open the pipe (a DACL with one entry: this user's SID), remote machines are refused
// (PIPE_REJECT_REMOTE_CLIENTS), the first instance is created with FILE_FLAG_FIRST_PIPE_INSTANCE (another process
// owning the name is an error, not a second server), a request line longer than the limit ends the connection, and a
// page cannot reach the channel: a page has no way to open a pipe or to send a line.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"
import "wb:base"
import "wb:host"

foreign import advapi32_srv "system:Advapi32.lib"
foreign import kernel32_srv "system:Kernel32.lib"

@(default_calling_convention = "system", private)
foreign advapi32_srv {
	ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc(sddl: win.LPCWSTR, revision: win.DWORD, sd: ^rawptr, size: ^win.ULONG) -> win.BOOL ---
}

@(default_calling_convention = "system", private)
foreign kernel32_srv {
	GetFullPathNameW :: proc(name: win.LPCWSTR, size: win.DWORD, buffer: win.LPWSTR, file_part: ^win.LPWSTR) -> win.DWORD ---
}

Handler  :: proc(user: rawptr, conn: u64, line: []byte)   // the loop thread; `line` is valid during the call
On_Close :: proc(user: rawptr, conn: u64)                 // the loop thread: the client has gone

@(private)
Conn :: struct {
	id:        u64,
	pipe:      win.HANDLE,
	thread:    ^thread.Thread,
	out_event: win.HANDLE,
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
	pipe_name:   win.wstring,
	stop_event:  win.HANDLE,
	first_pipe:  win.HANDLE,
	accept:      ^thread.Thread,
	sd:          rawptr,
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

// Opens the pipe and starts listening. `name` is valid_name. On failure `err` says why (no server then).
start :: proc(loop: ^host.Loop, name: string, max_message, max_clients: int, handler: Handler, on_close: On_Close, user: rawptr) -> (err: string) {
	if srv.running { return "the remote channel is already running" }
	if !valid_name(name) { return "invalid name: use letters, digits, '-', '_' and '.'" }
	srv = {loop = loop, handler = handler, on_close = on_close, user = user, max_message = max_message, max_clients = max_clients}
	srv.pipe_name = win.utf8_to_wstring(pipe_path(name), base.process_allocator())
	sddl := strings.concatenate({"D:P(A;;GA;;;", current_user_sid(), ")"}, context.temp_allocator)
	if sddl == "D:P(A;;GA;;;)" || !ConvertStringSecurityDescriptorToSecurityDescriptorW(win.utf8_to_wstring(sddl, context.temp_allocator), 1, &srv.sd, nil) {
		code := win.GetLastError()
		delete_wstring(srv.pipe_name)
		srv = {}
		return fmt.tprintf("cannot build the access list of the pipe (%s, error %d)", sddl, code)
	}
	srv.stop_event = win.CreateEventW(nil, true, false, nil)
	srv.first_pipe = create_instance(true)
	if srv.first_pipe == win.INVALID_HANDLE_VALUE {
		code := win.GetLastError()
		win.CloseHandle(srv.stop_event)
		win.LocalFree(srv.sd)
		delete_wstring(srv.pipe_name)
		srv = {}
		if code == win.ERROR_ACCESS_DENIED { return "the pipe name is taken by another process" }
		return "cannot create the pipe"
	}
	srv.accept = thread.create(accept_main)
	srv.accept.init_context = nil
	thread.start(srv.accept)
	srv.running = true
	return ""
}

@(private)
delete_wstring :: proc(w: win.wstring) { free(rawptr(w), base.process_allocator()) }

// Stops listening and drops every client (their threads end, their pipes close). Loop thread.
stop :: proc() {
	if !srv.running { return }
	srv.running = false
	// the threads have one thing left to do, end: they run at the stopper's priority or above while it waits for them (a thread
	// that waits in the kernel needs a time slice to see its event, and a loaded machine gives them seconds)
	host.shutdown_step("remote_stop: accept thread")
	sync.mutex_lock(&srv.mu)
	for c in srv.conns { if c.thread != nil { win.SetThreadPriority(c.thread.win32_thread, 2) } }
	sync.mutex_unlock(&srv.mu)
	win.SetThreadPriority(srv.accept.win32_thread, 2)
	win.SetEvent(srv.stop_event)
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
	win.CloseHandle(srv.stop_event)
	win.LocalFree(srv.sd)
	delete_wstring(srv.pipe_name)
	srv = {}
}

@(private)
conn_free :: proc(c: ^Conn) {
	thread.join(c.thread)
	thread.destroy(c.thread)
	for l in c.inbox { delete(l, base.process_allocator()) }
	for l in c.outbox { delete(l, base.process_allocator()) }
	delete(c.inbox); delete(c.outbox)
	win.CloseHandle(c.out_event)
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
		win.SetEvent(c.out_event)
		return true
	}
	return false
}

// Ends the connection of `id` once what was queued for it has been written.
close_client :: proc(id: u64) {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	for c in srv.conns {
		if c.id == id { c.closing = true; win.SetEvent(c.out_event) }
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

@(private)
create_instance :: proc(first: bool) -> win.HANDLE {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), lpSecurityDescriptor = srv.sd, bInheritHandle = false}
	open := win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_OVERLAPPED
	if first { open |= win.FILE_FLAG_FIRST_PIPE_INSTANCE }
	return win.CreateNamedPipeW(srv.pipe_name, open, win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
		255, 64 << 10, 64 << 10, 0, &sa)
}

// A wake for the loop: the task runs on_input (the data is not used: the server is a global).
@(private)
notify :: proc() { host.post(srv.loop, on_input, nil) }

@(private)
accept_main :: proc(_: ^thread.Thread) {
	context = base.process_context()
	ev := win.CreateEventW(nil, true, false, nil)
	defer win.CloseHandle(ev)
	pipe := srv.first_pipe
	for pipe != win.INVALID_HANDLE_VALUE {
		win.ResetEvent(ev)
		ov := win.OVERLAPPED{hEvent = ev}
		if !win.ConnectNamedPipe(pipe, &ov) {
			switch win.GetLastError() {
			case win.ERROR_IO_PENDING:
				handles := [2]win.HANDLE{ev, srv.stop_event}
				if win.WaitForMultipleObjects(2, &handles[0], false, win.INFINITE) != win.WAIT_OBJECT_0 {
					win.CancelIoEx(pipe, &ov)
					n: win.DWORD
					win.GetOverlappedResult(pipe, &ov, &n, true)
					win.CloseHandle(pipe)
					return
				}
			case win.ERROR_PIPE_CONNECTED:   // the client came between the creation and the call
			case:
				win.CloseHandle(pipe)
				return
			}
		}
		if sync.atomic_load(&srv.active) >= srv.max_clients {
			win.CloseHandle(pipe)   // turned away: the client sees the pipe close
		} else {
			start_client(pipe)
		}
		if win.WaitForSingleObject(srv.stop_event, 0) == win.WAIT_OBJECT_0 { return }
		pipe = create_instance(false)
	}
}

@(private)
start_client :: proc(pipe: win.HANDLE) {
	c := new(Conn, base.process_allocator())
	c.pipe = pipe
	c.out_event = win.CreateEventW(nil, false, false, nil)
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
		win.CloseHandle(c.pipe)
		sync.mutex_lock(&srv.mu)
		c.done = true
		sync.mutex_unlock(&srv.mu)
		sync.atomic_sub(&srv.active, 1)
		notify()
	}
	read_ev := win.CreateEventW(nil, true, false, nil)
	write_ev := win.CreateEventW(nil, true, false, nil)
	defer { win.CloseHandle(read_ev); win.CloseHandle(write_ev) }
	buf := make([]byte, 64 << 10, base.process_allocator())
	defer delete(buf, base.process_allocator())
	pending := make([dynamic]byte, base.process_allocator())
	defer delete(pending)
	ov := win.OVERLAPPED{hEvent = read_ev}
	reading := false
	handles := [3]win.HANDLE{read_ev, c.out_event, srv.stop_event}
	defer if reading {
		win.CancelIoEx(c.pipe, &ov)
		n: win.DWORD
		win.GetOverlappedResult(c.pipe, &ov, &n, true)
	}
	for {
		if !reading {
			win.ResetEvent(read_ev)
			ov = {hEvent = read_ev}
			if !win.ReadFile(c.pipe, raw_data(buf), win.DWORD(len(buf)), nil, &ov) && win.GetLastError() != win.ERROR_IO_PENDING { return }
			reading = true
		}
		switch win.WaitForMultipleObjects(3, &handles[0], false, win.INFINITE) {
		case win.WAIT_OBJECT_0:
			n: win.DWORD
			reading = false
			if !win.GetOverlappedResult(c.pipe, &ov, &n, false) || n == 0 { return }   // the client closed
			append(&pending, ..buf[:n])
			if !take_lines(c, &pending, write_ev) { return }
		case win.WAIT_OBJECT_0 + 1:
			if !flush_outbox(c, write_ev) { return }
			sync.mutex_lock(&srv.mu)
			closing := c.closing && len(c.outbox) == 0
			sync.mutex_unlock(&srv.mu)
			if closing { return }
		case:
			return   // the server stops
		}
	}
}

// Moves the complete lines of `pending` to the inbox. False: a line is longer than the limit (answered, then the end).
@(private)
take_lines :: proc(c: ^Conn, pending: ^[dynamic]byte, write_ev: win.HANDLE) -> bool {
	got := false
	for {
		nl := -1
		for b, i in pending^ { if b == '\n' { nl = i; break } }
		if nl < 0 { break }
		line := pending[:nl]
		if nl > 0 && line[nl - 1] == '\r' { line = line[:nl - 1] }
		if len(line) > srv.max_message { too_long(c, write_ev); return false }
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
	if len(pending) > srv.max_message { too_long(c, write_ev); return false }
	if got { notify() }
	return true
}

@(private)
too_long :: proc(c: ^Conn, write_ev: win.HANDLE) {
	msg := transmute([]byte)string(`{"id":null,"error":{"code":-32600,"message":"request line longer than browser.remote.max_message_bytes"}}` + "\n")
	write_all(c, msg, write_ev)
}

@(private)
flush_outbox :: proc(c: ^Conn, write_ev: win.HANDLE) -> bool {
	for {
		sync.mutex_lock(&srv.mu)
		if len(c.outbox) == 0 { sync.mutex_unlock(&srv.mu); return true }
		line := c.outbox[0]
		ordered_remove(&c.outbox, 0)
		sync.mutex_unlock(&srv.mu)
		ok := write_all(c, line, write_ev)
		delete(line, base.process_allocator())
		if !ok { return false }
	}
}

// Writes all of `data`, waiting for the pipe (a client that does not read ends with the server, not before).
@(private)
write_all :: proc(c: ^Conn, data: []byte, write_ev: win.HANDLE) -> bool {
	rest := data
	for len(rest) > 0 {
		win.ResetEvent(write_ev)
		ov := win.OVERLAPPED{hEvent = write_ev}
		chunk := min(len(rest), 1 << 20)
		if !win.WriteFile(c.pipe, raw_data(rest), win.DWORD(chunk), nil, &ov) && win.GetLastError() != win.ERROR_IO_PENDING { return false }
		handles := [2]win.HANDLE{write_ev, srv.stop_event}
		if win.WaitForMultipleObjects(2, &handles[0], false, win.INFINITE) != win.WAIT_OBJECT_0 {
			win.CancelIoEx(c.pipe, &ov)
			n: win.DWORD
			win.GetOverlappedResult(c.pipe, &ov, &n, true)
			return false
		}
		n: win.DWORD
		if !win.GetOverlappedResult(c.pipe, &ov, &n, false) || n == 0 { return false }
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
// The user, the profile's files

@(private)
current_user_sid :: proc() -> string {
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) { return "" }
	defer win.CloseHandle(token)
	// (a SID is at most 68 bytes: one call into a buffer that is always large enough)
	buf: [512]byte
	size: win.DWORD
	if !win.GetTokenInformation(token, .TokenUser, &buf[0], len(buf), &size) { return "" }
	user := (^win.TOKEN_USER)(&buf[0])
	text: win.LPCWSTR
	if !win.ConvertSidToStringSidW((^win.SID)(user.User.Sid), &text) { return "" }
	defer win.LocalFree(rawptr(text))
	s, _ := win.wstring_to_utf8(win.wstring(rawptr(text)), -1, context.temp_allocator)
	return s
}

// The full path of `p` as the system resolves it (relative to the current folder), or `p` itself.
full_path :: proc(p: string) -> string {
	w := win.utf8_to_wstring(p, context.temp_allocator)
	buf: [1024]u16
	n := GetFullPathNameW(w, len(buf), &buf[0], nil)
	if n == 0 || int(n) >= len(buf) { return p }
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return err == nil ? s : p
}

info_path :: proc(profile_dir: string) -> string {
	return strings.concatenate({profile_dir, "/remote.json"}, context.temp_allocator)
}

// <profile>\remote.json: what a client reads to find this instance.
write_info :: proc(profile_dir, name, version: string) -> bool {
	pid := int(win.GetCurrentProcessId())
	text := strings.concatenate({
		`{"name":`, quote(name), `,"pipe":`, quote(pipe_path(name)), `,"pid":`, itoa(pid),
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

_ :: runtime
