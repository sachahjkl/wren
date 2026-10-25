#+build windows
package client

// The client end of the pipe: overlapped I/O so that every wait has a limit, one request at a time.

import "core:encoding/json"
import "core:fmt"
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

Call_Error :: enum u8 { None, No_Server, Timeout, Closed, Server }

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
		for b, i in c.pending {
			if b == '\n' {
				l := strings.clone(string(c.pending[:i]), context.temp_allocator)
				remove_range(&c.pending, 0, i + 1)
				return l, .None
			}
		}
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

Reply :: struct {
	result:  string,   // JSON text of the result
	message: string,   // an error's message
	data:    string,   // an error's data (JSON text)
	code:    int,
}

// Sends a request and waits for its answer (events that arrive meanwhile are dropped). `params` is JSON text ("" = none).
// The wait is `timeout_ms` (the server's own wait limits are shorter or equal: its timeout error comes first).
call :: proc(c: ^Conn, method, params: string, timeout_ms: int) -> (Reply, Call_Error) {
	c.next_id += 1
	id := c.next_id
	req := fmt.tprintf(`{{"id":%d,"method":%s,"params":%s}}`, id, remote.quote(method), params == "" ? "{}" : params)
	if e := write_line(c, req, timeout_ms); e != .None { return {}, e }
	deadline := time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	for {
		line, e := read_line(c, deadline)
		if e != .None { return {}, e }
		v, perr := json.parse(transmute([]byte)line, json.Specification.JSON, true, context.temp_allocator)
		obj, ok := v.(json.Object)
		if perr != .None || !ok { continue }
		if got, has := remote.param_int(obj, "id"); !has || got != id { continue }
		if errobj, is_err := remote.param_object(obj, "error"); is_err {
			r := Reply{code = 0}
			r.code, _ = remote.param_int(errobj, "code")
			r.message, _ = remote.param_string(errobj, "message")
			if at := strings.index(line, `"data":`); at >= 0 && strings.has_suffix(line, "}}") { r.data = line[at + len(`"data":`):len(line) - 2] }
			return r, .Server
		}
		// the result as the server wrote it (re-writing it would change its numbers): from "result": to the closing brace
		if at := strings.index(line, `"result":`); at >= 0 && strings.has_suffix(line, "}") { return Reply{result = line[at + len(`"result":`):len(line) - 1]}, .None }
		res, _ := obj["result"]
		s, merr := json.marshal(res, {}, context.temp_allocator)
		if merr != nil { return {}, .Closed }
		return Reply{result = string(s)}, .None
	}
}
