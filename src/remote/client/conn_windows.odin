#+build windows
package client

// The client end of the pipe: overlapped I/O so that every wait has a limit, one request at a time.

import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:remote"

foreign import kernel32_cl "system:Kernel32.lib"

@(default_calling_convention = "system", private)
foreign kernel32_cl {
	WaitNamedPipeW :: proc(name: win.LPCWSTR, timeout: win.DWORD) -> win.BOOL ---
}

Conn :: struct {
	pipe:    win.HANDLE,
	read_ev: win.HANDLE,
	write_ev: win.HANDLE,
	pending: [dynamic]byte,   // bytes read, past the last line taken
	next_id: int,
	pid:     int,             // the server's process, once known
}

@(private = "file") SECURITY_IDENTIFICATION :: 0x00010000   // SECURITY_IMPERSONATION_LEVEL SecurityIdentification << 16

// Opens the pipe of `name`, retrying while it does not exist yet or is busy, for up to `wait_ms`.
connect :: proc(c: ^Conn, name: string, wait_ms: int) -> bool {
	path := win.utf8_to_wstring(remote.pipe_path(name), context.temp_allocator)
	deadline := time.tick_add(time.tick_now(), time.Duration(wait_ms) * time.Millisecond)
	delay := 1
	for {
		// (SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION: a server that is not Wren may read who we are but cannot act as us)
		h := win.CreateFileW(path, win.GENERIC_READ | win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, win.FILE_FLAG_OVERLAPPED | win.SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nil)
		if h != win.INVALID_HANDLE_VALUE {
			c.pipe = h
			c.read_ev = win.CreateEventW(nil, true, false, nil)
			c.write_ev = win.CreateEventW(nil, true, false, nil)
			return true
		}
		err := win.GetLastError()
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return false }
		if err == win.ERROR_PIPE_BUSY { WaitNamedPipeW(path, 50) } else {
			time.sleep(time.Duration(delay) * time.Millisecond)
			delay = min(delay * 2, 25)
		}
	}
}

disconnect :: proc(c: ^Conn) {
	if c.pipe != nil { win.CloseHandle(c.pipe); win.CloseHandle(c.read_ev); win.CloseHandle(c.write_ev) }
	delete(c.pending)
	c^ = {}
}

@(private)
write_line :: proc(c: ^Conn, line: string, timeout_ms: int) -> Call_Error {
	data := transmute([]byte)strings.concatenate({line, "\n"}, context.temp_allocator)
	for len(data) > 0 {
		win.ResetEvent(c.write_ev)
		ov := win.OVERLAPPED{hEvent = c.write_ev}
		if !win.WriteFile(c.pipe, raw_data(data), win.DWORD(min(len(data), 1 << 20)), nil, &ov) && win.GetLastError() != win.ERROR_IO_PENDING { return .Closed }
		if win.WaitForSingleObject(c.write_ev, win.DWORD(timeout_ms)) != win.WAIT_OBJECT_0 {
			win.CancelIoEx(c.pipe, &ov)
			n: win.DWORD
			win.GetOverlappedResult(c.pipe, &ov, &n, true)
			return .Timeout
		}
		n: win.DWORD
		if !win.GetOverlappedResult(c.pipe, &ov, &n, false) || n == 0 { return .Closed }
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
		if left <= 0 { return "", .Timeout }
		win.ResetEvent(c.read_ev)
		ov := win.OVERLAPPED{hEvent = c.read_ev}
		if !win.ReadFile(c.pipe, &buf[0], len(buf), nil, &ov) && win.GetLastError() != win.ERROR_IO_PENDING { return "", .Closed }
		if win.WaitForSingleObject(c.read_ev, win.DWORD(left)) != win.WAIT_OBJECT_0 {
			win.CancelIoEx(c.pipe, &ov)
			n: win.DWORD
			win.GetOverlappedResult(c.pipe, &ov, &n, true)
			if n == 0 { return "", .Timeout }
			append(&c.pending, ..buf[:n])
			continue
		}
		n: win.DWORD
		if !win.GetOverlappedResult(c.pipe, &ov, &n, false) || n == 0 { return "", .Closed }
		append(&c.pending, ..buf[:n])
	}
}


