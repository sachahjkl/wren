#+build windows
package remote

// The pipe server. Overlapped I/O on threads that wait in the kernel: one accepts, one per client reads and writes. A
// request line is queued for the interface thread and `host.post` wakes its loop: no timer, no polling, nothing runs while no
// client sends anything, and nothing exists at all in a process that did not start the channel (server.odin: what the
// socket server of Linux shares).
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
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"
import "wb:base"
import "wb:host"

// The wait before trying again when no pipe instance could be made; and after this many failed connects, the wait between
// them, so a loop that keeps failing does not spin (ms).
PIPE_INSTANCE_RETRY_MS :: 100
PIPE_FAILURES_BEFORE_WAIT :: 3
PIPE_FAILURE_WAIT_MS :: 50

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

@(private)
Conn_Sys :: struct {
	pipe:      win.HANDLE,
	out_event: win.HANDLE,   // the outbox has lines, or the loop asks for the end
	write_ev:  win.HANDLE,   // the overlapped writes of the client's thread
}

@(private)
Server_Sys :: struct {
	pipe_name:  win.wstring,
	stop_event: win.HANDLE,
	first_pipe: win.HANDLE,
	sd:         rawptr,
}

// Opens the pipe and starts listening. `name` is valid_name. On failure `err` says why (no server then).
start :: proc(loop: ^host.Loop, name: string, max_message, max_clients: int, handler: Handler, on_close: On_Close, user: rawptr) -> (err: string) {
	if srv.running { return "the remote channel is already running" }
	if !valid_name(name) { return "invalid name: use letters, digits, '-', '_' and '.'" }
	// the loop is the caller's, kept until stop (rawptr: on purpose)
	srv = {loop = (^host.Loop)(rawptr(loop)), handler = handler, on_close = on_close, user = user, max_message = max_message, max_clients = max_clients}
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

// The threads have one thing left to do, end: they run at the stopper's priority or above while it waits for them (a thread
// that waits in the kernel needs a time slice to see its event, and a loaded machine gives them seconds).
@(private)
stop_threads :: proc() {
	sync.mutex_lock(&srv.mu)
	for c in srv.conns { if c.thread != nil { win.SetThreadPriority(c.thread.win32_thread, 2) } }
	sync.mutex_unlock(&srv.mu)
	win.SetThreadPriority(srv.accept.win32_thread, 2)
	win.SetEvent(srv.stop_event)
}

@(private)
server_close :: proc() {
	win.CloseHandle(srv.stop_event)
	win.LocalFree(srv.sd)
	delete_wstring(srv.pipe_name)
}

@(private)
signal :: proc(ev: win.HANDLE) { win.SetEvent(ev) }

@(private)
event_close :: proc(ev: win.HANDLE) { win.CloseHandle(ev) }

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

@(private)
accept_main :: proc(_: ^thread.Thread) {
	context = base.process_context()
	ev := win.CreateEventW(nil, true, false, nil)
	defer win.CloseHandle(ev)
	pipe := srv.first_pipe
	failures := 0
	// The server must always have an instance waiting: the loop only ends when it is asked to stop. A client that connects and
	// goes at once (a security query, a probe) makes ConnectNamedPipe fail with ERROR_NO_DATA, and a new instance may not be
	// made for a moment (out of resources): neither is a reason to stop listening, which would remove the pipe for good.
	for {
		if pipe == win.INVALID_HANDLE_VALUE {
			if win.WaitForSingleObject(srv.stop_event, PIPE_INSTANCE_RETRY_MS) == win.WAIT_OBJECT_0 { return }
			pipe = create_instance(false)
			continue
		}
		win.ResetEvent(ev)
		ov := win.OVERLAPPED{hEvent = ev}
		connected := true
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
				n: win.DWORD
				connected = bool(win.GetOverlappedResult(pipe, &ov, &n, false))
			case win.ERROR_PIPE_CONNECTED:   // the client came between the creation and the call
			case: connected = false          // ERROR_NO_DATA: it came and went before we listened
			}
		}
		if !connected {
			failures += 1
			next := create_instance(false)   // (before the old one goes: the name never disappears)
			win.CloseHandle(pipe)
			pipe = next
			if failures > PIPE_FAILURES_BEFORE_WAIT && win.WaitForSingleObject(srv.stop_event, PIPE_FAILURE_WAIT_MS) == win.WAIT_OBJECT_0 {   // (no spin if it keeps failing)
				if pipe != win.INVALID_HANDLE_VALUE { win.CloseHandle(pipe) }
				return
			}
			continue
		}
		failures = 0
		if !room_for_client() {
			win.CloseHandle(pipe)   // turned away: the client sees the pipe close
		} else {
			c := new(Conn, base.process_allocator())
			c.pipe = pipe
			c.out_event = win.CreateEventW(nil, false, false, nil)
			conn_start(c)
		}
		if win.WaitForSingleObject(srv.stop_event, 0) == win.WAIT_OBJECT_0 { return }
		pipe = create_instance(false)
	}
}

// The other end of `c` is still open (what it wrote and has not been read counts as there too).
@(private)
client_there :: proc(c: ^Conn) -> bool {
	return bool(win.PeekNamedPipe(c.pipe, nil, 0, nil, nil, nil)) || win.GetLastError() != win.ERROR_BROKEN_PIPE
}

@(private)
client_main :: proc(t: ^thread.Thread) {
	context = base.process_context()
	c := (^Conn)(t.data)
	defer { conn_done(c); win.CloseHandle(c.pipe) }
	if srv.client_hold != nil { srv.client_hold() }
	read_ev := win.CreateEventW(nil, true, false, nil)
	c.write_ev = win.CreateEventW(nil, true, false, nil)
	defer { win.CloseHandle(read_ev); win.CloseHandle(c.write_ev) }
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
			if !take_lines(c, &pending) { return }
		case win.WAIT_OBJECT_0 + 1:
			if !flush_outbox(c) || conn_closing(c) { return }
		case:
			return   // the server stops
		}
	}
}

// Writes all of `data`, waiting for the pipe (a client that does not read ends with the server, not before).
@(private)
write_all :: proc(c: ^Conn, data: []byte) -> bool {
	rest := data
	for len(rest) > 0 {
		win.ResetEvent(c.write_ev)
		ov := win.OVERLAPPED{hEvent = c.write_ev}
		chunk := min(len(rest), 1 << 20)
		if !win.WriteFile(c.pipe, raw_data(rest), win.DWORD(chunk), nil, &ov) && win.GetLastError() != win.ERROR_IO_PENDING { return false }
		handles := [2]win.HANDLE{c.write_ev, srv.stop_event}
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

_ :: runtime
