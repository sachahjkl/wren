package remote

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import win "core:sys/windows"
import "wb:host"

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

// How long the socket's test turns the loop for what it expects, and the loop's wait each time (ms).
@(private = "file") TCP_PUMP_DEADLINE :: 2 * time.Second
@(private = "file") TCP_PUMP_WAIT_MS :: 20
@(private = "file") TCP_HELD_CLIENTS :: 2
@(private = "file") tcp_held_started: int   // (atomic)
@(private = "file") tcp_held_release: sync.Sema

@(private = "file")
tcp_open_client :: proc() -> win.SOCKET {
	s := win.socket(win.AF_INET, win.SOCK_STREAM, win.IPPROTO_TCP)
	addr := win.sockaddr_in{sin_family = u16(win.AF_INET), sin_port = u16be(u16(tcp_port())), sin_addr = {s_addr = tcp_loopback_be()}}
	win.connect(s, cast(^win.SOCKADDR_STORAGE_LH)&addr, size_of(addr))
	return s
}

// The CDP's socket as the pipe (a_client_is_not_turned_away_by_clients_that_have_gone): the threads of the clients that went, held up, leave room for the next one.
@(test)
a_socket_client_is_not_turned_away_by_clients_that_have_gone :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	served: int
	testing.expect_value(t, tcp_start((^host.Loop)(rawptr(&loop)), 0, TCP_HELD_CLIENTS, proc(user: rawptr, conn: u64, data: []byte) { (^int)(user)^ += 1 }, nil, &served), "")
	t_srv.client_hold = proc() { if sync.atomic_add(&tcp_held_started, 1) < TCP_HELD_CLIENTS { sync.sema_wait(&tcp_held_release) } }
	gone: [TCP_HELD_CLIENTS]win.SOCKET
	for &s in gone { s = tcp_open_client() }
	deadline := time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
	for tcp_client_count() < TCP_HELD_CLIENTS && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
	for s in gone { win.closesocket(s) }
	c := tcp_open_client()
	win.send(c, raw_data(string("x")), 1, 0)
	deadline = time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
	for served == 0 && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
	testing.expect_value(t, served, 1)
	sync.sema_post(&tcp_held_release, TCP_HELD_CLIENTS)
	win.closesocket(c)
	tcp_stop()
	host.loop_drain(&loop)
}
