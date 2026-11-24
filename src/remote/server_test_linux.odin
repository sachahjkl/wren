package remote

import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:time"
import "wb:host"

// The client side of server_test.odin: the socket connected as `wren ctl` connects it.

@(private)
Test_Client :: linux.Fd

@(private)
NO_CLIENT :: linux.Fd(-1)

@(private)
open_client :: proc(name: string) -> Test_Client {
	for _ in 0 ..< 100 {
		if s := unix_connect(pipe_path(name)); s >= 0 { return s }
		time.sleep(5 * time.Millisecond)
	}
	return -1
}

@(private)
write_text :: proc(s: Test_Client, text: string) -> bool {
	n, err := linux.send(s, transmute([]u8)text, {.NOSIGNAL})
	return err == .NONE && n == len(text)
}

@(private)
read_text :: proc(s: Test_Client) -> string {
	buf: [1024]byte
	fds := []linux.Poll_Fd{{fd = s, events = {.IN}}}
	if n, _ := linux.poll(fds, 2000); n <= 0 { return "" }
	n, err := linux.recv(s, buf[:], {})
	if err != .NONE || n <= 0 { return "" }
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@(private)
client_close :: proc(s: Test_Client) { linux.close(s) }

// A socket another live process listens on is not taken over; one left by a process that died is.
@(test)
a_live_socket_is_kept_and_a_dead_one_replaced :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	_, safe := socket_dir()
	testing.expect(t, safe, "the socket folder is the user's alone")
	path := pipe_path("unit-live")
	addr, _ := unix_address(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	linux.unlink(cpath)
	other, _ := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	testing.expect(t, linux.bind(other, &addr) == .NONE && linux.listen(other, 1) == .NONE)
	testing.expect_value(t, start(&loop, "unit-live", 4096, 4, nil, nil, nil), "the socket name is taken by another process")
	linux.close(other)   // the file stays, nobody listens: what a crash leaves
	testing.expect_value(t, start(&loop, "unit-live", 4096, 4, nil, nil, nil), "")
	c := open_client("unit-live")
	testing.expect(t, c != NO_CLIENT, "the new server answers on the same path")
	client_close(c)
	stop()
	host.loop_drain(&loop)
	st: linux.Stat
	testing.expect(t, linux.lstat(cpath, &st) == .ENOENT, "stop removes the socket file")
}

@(private = "file") TCP_PUMP_DEADLINE :: 2 * time.Second
@(private = "file") TCP_PUMP_WAIT_MS  :: 20
@(private = "file") TCP_HELD_CLIENTS  :: 2
@(private = "file") tcp_held_started: int   // (atomic)
@(private = "file") tcp_held_release: sync.Sema

@(private = "file")
tcp_open_ipv4 :: proc(port: int) -> linux.Fd {
	s, err := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if err != .NONE { return -1 }
	addr := linux.Sock_Addr_In{sin_family = .INET, sin_port = u16be(u16(port)), sin_addr = {127, 0, 0, 1}}
	for {
		e := linux.connect(s, &addr)
		if e == .EINTR { continue }
		if e != .NONE { linux.close(s); return -1 }
		return s
	}
}

@(private = "file")
tcp_open_ipv6 :: proc(port: int) -> linux.Fd {
	s, err := linux.socket(.INET6, .STREAM, {.CLOEXEC}, .TCP)
	if err != .NONE { return -1 }
	addr := linux.Sock_Addr_In6{sin6_family = .INET6, sin6_port = u16be(u16(port))}
	addr.sin6_addr[15] = 1
	for {
		e := linux.connect(s, &addr)
		if e == .EINTR { continue }
		if e != .NONE { linux.close(s); return -1 }
		return s
	}
}

@(test)
tcp_server_round_trip_and_close :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	State :: struct {
		got:    [dynamic]string,
		closed: [dynamic]u64,
		echo:   bool,
		close_after: bool,
	}
	st := State{echo = true}
	defer {
		for s in st.got { delete(s) }
		delete(st.got)
		delete(st.closed)
	}
	on_data :: proc(user: rawptr, conn: u64, data: []byte) {
		s := (^State)(user)
		append(&s.got, strings.clone(string(data)))
		if s.echo { tcp_send(conn, data) }
		if s.close_after { tcp_close_client(conn) }
	}
	on_close :: proc(user: rawptr, conn: u64) { append(&(^State)(user).closed, conn) }

	testing.expect_value(t, tcp_start((^host.Loop)(rawptr(&loop)), 0, 4, on_data, on_close, rawptr(&st)), "")
	testing.expect(t, tcp_running(), "tcp server is running")
	port := tcp_port()
	testing.expect(t, port > 0, "ephemeral port assigned")
	testing.expect_value(t, tcp_start((^host.Loop)(rawptr(&loop)), 0, 4, on_data, on_close, rawptr(&st)), "the CDP channel is already running")

	c := tcp_open_ipv4(port)
	testing.expect(t, c >= 0, "connected over 127.0.0.1")
	testing.expect(t, write_text(c, "hello-cdp"))
	deadline := time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
	for len(st.got) == 0 && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
	testing.expect_value(t, len(st.got), 1)
	if len(st.got) == 1 { testing.expect_value(t, st.got[0], "hello-cdp") }
	testing.expect_value(t, read_text(c), "hello-cdp")
	testing.expect_value(t, len(tcp_client_ids()), 1)

	// Server-initiated close flushes queued reply before closing.
	st.close_after = true
	testing.expect(t, write_text(c, "bye"))
	deadline = time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
	for len(st.closed) == 0 && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
	testing.expect_value(t, read_text(c), "bye")
	testing.expect_value(t, len(st.closed), 1)
	linux.close(c)

	// If IPv6 loopback listener bound, verify ::1 accepts too.
	if t_srv.listener6 >= 0 {
		st.close_after = false
		c6 := tcp_open_ipv6(port)
		testing.expect(t, c6 >= 0, "connected over ::1")
		if c6 >= 0 {
			testing.expect(t, write_text(c6, "v6"))
			deadline = time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
			for len(st.got) < 3 && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
			testing.expect_value(t, read_text(c6), "v6")
			linux.close(c6)
			deadline = time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
			for len(st.closed) < 2 && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
			testing.expect_value(t, len(st.closed), 2)
		}
	}

	tcp_stop()
	testing.expect(t, !tcp_running(), "tcp server stopped")
	host.loop_drain(&loop)
}

@(test)
a_socket_client_is_not_turned_away_by_clients_that_have_gone :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	served := new(int)
	defer free(served)
	sync.atomic_store(&tcp_held_started, 0)
	testing.expect_value(t, tcp_start((^host.Loop)(rawptr(&loop)), 0, TCP_HELD_CLIENTS, proc(user: rawptr, conn: u64, data: []byte) { (^int)(user)^ += 1 }, nil, served), "")
	t_srv.client_hold = proc() { if sync.atomic_add(&tcp_held_started, 1) < TCP_HELD_CLIENTS { sync.sema_wait(&tcp_held_release) } }
	gone: [TCP_HELD_CLIENTS]linux.Fd
	for &s in gone { s = tcp_open_ipv4(tcp_port()) }
	deadline := time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
	for tcp_client_count() < TCP_HELD_CLIENTS && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
	for s in gone { linux.close(s) }
	c := tcp_open_ipv4(tcp_port())
	testing.expect(t, c >= 0)
	_ = write_text(c, "x")
	deadline = time.tick_add(time.tick_now(), TCP_PUMP_DEADLINE)
	for served^ == 0 && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, TCP_PUMP_WAIT_MS) }
	testing.expect_value(t, served^, 1)
	sync.sema_post(&tcp_held_release, TCP_HELD_CLIENTS)
	linux.close(c)
	tcp_stop()
	host.loop_drain(&loop)
}
