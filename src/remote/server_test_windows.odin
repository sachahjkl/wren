package remote

import "core:strings"
import "core:time"
import win "core:sys/windows"

// The client side of server_test.odin: the pipe opened as `wren ctl` opens it.

@(private)
Test_Client :: win.HANDLE

@(private)
NO_CLIENT :: win.INVALID_HANDLE_VALUE

@(private)
open_client :: proc(name: string) -> Test_Client {
	path := win.utf8_to_wstring(pipe_path(name), context.temp_allocator)
	for _ in 0 ..< 100 {
		h := win.CreateFileW(path, win.GENERIC_READ | win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, 0, nil)
		if h != win.INVALID_HANDLE_VALUE { return h }
		time.sleep(5 * time.Millisecond)
	}
	return win.INVALID_HANDLE_VALUE
}

@(private)
write_text :: proc(h: Test_Client, s: string) -> bool {
	n: win.DWORD
	return bool(win.WriteFile(h, raw_data(s), win.DWORD(len(s)), &n, nil)) && int(n) == len(s)
}

@(private)
read_text :: proc(h: Test_Client) -> string {
	buf: [1024]byte
	n: win.DWORD
	if !win.ReadFile(h, &buf[0], len(buf), &n, nil) || n == 0 { return "" }
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@(private)
client_close :: proc(h: Test_Client) { win.CloseHandle(h) }
