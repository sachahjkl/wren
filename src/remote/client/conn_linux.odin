package client

// The client end of the Unix socket (remote.pipe_path): every wait has a limit (poll), one request at a time.

import "core:strings"
import "core:sys/linux"
import "core:time"
import "wb:remote"

Conn :: struct {
	sock:    linux.Fd,
	open:    bool,
	pending: [dynamic]byte,   // bytes read, past the last line taken
	next_id: int,
	pid:     int,             // the server's process, once known
}

// Connects to the socket of `name`, retrying while it does not exist yet (a Wren starting), for up to `wait_ms`.
connect :: proc(c: ^Conn, name: string, wait_ms: int) -> bool {
	if _, safe := remote.socket_dir(); !safe { return false }   // (a folder another user could own: never talk there)
	path := remote.pipe_path(name)
	deadline := time.tick_add(time.tick_now(), time.Duration(wait_ms) * time.Millisecond)
	delay := 1
	for {
		if s := remote.unix_connect(path); s >= 0 {
			c.sock, c.open = s, true
			return true
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return false }
		time.sleep(time.Duration(delay) * time.Millisecond)
		delay = min(delay * 2, 25)
	}
}

disconnect :: proc(c: ^Conn) {
	if c.open { linux.close(c.sock) }
	delete(c.pending)
	c^ = {}
}

// Waits until `s` is ready for `ev` or `ms` passed: false on the time limit or an error.
@(private = "file")
ready :: proc(s: linux.Fd, ev: linux.Fd_Poll_Events, ms: int) -> bool {
	for {
		fds := []linux.Poll_Fd{{fd = s, events = ev}}
		n, err := linux.poll(fds, i32(max(ms, 0)))
		if err == .EINTR { continue }
		return err == .NONE && n > 0
	}
}

@(private)
write_line :: proc(c: ^Conn, line: string, timeout_ms: int) -> Call_Error {
	data := transmute([]byte)strings.concatenate({line, "\n"}, context.temp_allocator)
	deadline := time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	for len(data) > 0 {
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		if left <= 0 || !ready(c.sock, {.OUT}, left) { return .Timeout }
		n, err := linux.send(c.sock, data[:min(len(data), 1 << 20)], {.NOSIGNAL, .DONTWAIT})
		if err == .EINTR || err == .EAGAIN { continue }
		if err != .NONE || n <= 0 { return .Closed }
		data = data[n:]
	}
	return .None
}

// The next line (without its newline), waiting at most until `deadline`.
@(private)
read_line :: proc(c: ^Conn, deadline: time.Tick) -> (line: string, err: Call_Error) {
	buf: [64 << 10]byte
	for {
		if l, ok := take_line(&c.pending); ok { return l, .None }
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		if left <= 0 || !ready(c.sock, {.IN}, left) { return "", .Timeout }
		n, rerr := linux.recv(c.sock, buf[:], {.DONTWAIT})
		if rerr == .EINTR || rerr == .EAGAIN { continue }
		if rerr != .NONE || n <= 0 { return "", .Closed }
		append(&c.pending, ..buf[:n])
	}
}
