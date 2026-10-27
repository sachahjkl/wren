package remote

import "core:strings"
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
