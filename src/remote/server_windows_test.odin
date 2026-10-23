#+build windows
package remote

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"
import "wb:host"

@(private = "file")
Seen :: struct {
	lines:   [dynamic]string,
	closed:  [dynamic]u64,
	reply:   bool,
}

@(private = "file")
on_line :: proc(user: rawptr, conn: u64, line: []byte) {
	s := (^Seen)(user)
	append(&s.lines, strings.clone(string(line)))
	if s.reply { send(conn, `{"id":1,"result":{"ok":true}}`) }
}

@(private = "file")
on_gone :: proc(user: rawptr, conn: u64) { append(&(^Seen)(user).closed, conn) }

@(private = "file")
seen_destroy :: proc(s: ^Seen) {
	for l in s.lines { delete(l) }
	delete(s.lines); delete(s.closed)
}

@(private = "file")
open_client :: proc(name: string) -> win.HANDLE {
	path := win.utf8_to_wstring(pipe_path(name), context.temp_allocator)
	for _ in 0 ..< 100 {
		h := win.CreateFileW(path, win.GENERIC_READ | win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, 0, nil)
		if h != win.INVALID_HANDLE_VALUE { return h }
		time.sleep(5 * time.Millisecond)
	}
	return win.INVALID_HANDLE_VALUE
}

@(private = "file")
write_text :: proc(h: win.HANDLE, s: string) -> bool {
	n: win.DWORD
	return bool(win.WriteFile(h, raw_data(s), win.DWORD(len(s)), &n, nil)) && int(n) == len(s)
}

@(private = "file")
read_text :: proc(h: win.HANDLE) -> string {
	buf: [1024]byte
	n: win.DWORD
	if !win.ReadFile(h, &buf[0], len(buf), &n, nil) || n == 0 { return "" }
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// Runs the loop until `done` or two seconds.
@(private = "file")
pump :: proc(loop: ^host.Loop, done: proc(s: ^Seen) -> bool, s: ^Seen) -> bool {
	deadline := time.tick_add(time.tick_now(), 2 * time.Second)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		host.loop_wait(loop, 20)
		if done(s) { return true }
	}
	return false
}

@(private = "file")
unique_name :: proc(what: string) -> string {
	return fmt.tprintf("unit-%s-%d-%d", what, win.GetCurrentProcessId(), time.now()._nsec % 100000)
}

@(test)
a_request_gets_its_answer_through_the_loop :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	seen := Seen{reply = true}
	defer seen_destroy(&seen)
	name := unique_name("rt")
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, &seen), "")
	c := open_client(name)
	testing.expect(t, c != win.INVALID_HANDLE_VALUE)
	testing.expect(t, write_text(c, "{\"id\":1,\"method\":\"x\"}\r\n\n{\"id\":2}\n"))
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return len(s.lines) >= 2 }, &seen))
	testing.expect_value(t, seen.lines[0], `{"id":1,"method":"x"}`)   // (the CR is not part of the line, the empty line is skipped)
	testing.expect_value(t, seen.lines[1], `{"id":2}`)
	testing.expect(t, strings.has_prefix(read_text(c), `{"id":1,"result":{"ok":true}}`))
	win.CloseHandle(c)
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return len(s.closed) == 1 }, &seen))   // the client went: the loop is told
	stop()
	host.loop_drain(&loop)
}

@(test)
a_line_over_the_limit_ends_the_connection :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	seen: Seen
	defer seen_destroy(&seen)
	name := unique_name("big")
	testing.expect_value(t, start(&loop, name, 1024, 4, on_line, on_gone, &seen), "")
	c := open_client(name)
	big, _ := strings.repeat("a", 3000, context.temp_allocator)
	write_text(c, big)
	reply := read_text(c)   // the error line, then the end
	testing.expect(t, strings.contains(reply, "max_message_bytes"))
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return len(s.closed) == 1 }, &seen))
	testing.expect_value(t, len(seen.lines), 0)
	win.CloseHandle(c)
	stop()
	host.loop_drain(&loop)
}

@(test)
a_name_taken_is_an_error_and_the_first_server_goes_on :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	seen: Seen
	defer seen_destroy(&seen)
	name := unique_name("taken")
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, &seen), "")
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, &seen), "the remote channel is already running")   // (this process)
	testing.expect(t, !valid_name("a/b") && !valid_name("") && !valid_name("..x") && valid_name("run-1_a.b"))
	stop()
	host.loop_drain(&loop)
}

@(test)
stopping_with_clients_connected_ends_their_threads :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	seen: Seen
	defer seen_destroy(&seen)
	name := unique_name("stop")
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, &seen), "")
	c1 := open_client(name)
	c2 := open_client(name)
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return client_count() == 2 }, &seen))
	stop()   // joins the accept thread and both clients' threads, closes the pipes
	testing.expect(t, !running())
	win.CloseHandle(c1); win.CloseHandle(c2)
	host.loop_drain(&loop)
}

@(test)
clients_over_the_limit_are_turned_away :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	seen: Seen
	defer seen_destroy(&seen)
	name := unique_name("max")
	testing.expect_value(t, start(&loop, name, 4096, 1, on_line, on_gone, &seen), "")
	c1 := open_client(name)
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return client_count() == 1 }, &seen))
	c2 := open_client(name)   // connects to the next instance, which is closed at once
	testing.expect(t, c2 != win.INVALID_HANDLE_VALUE)
	testing.expect_value(t, read_text(c2), "")
	win.CloseHandle(c2)
	stop()
	win.CloseHandle(c1)
	host.loop_drain(&loop)
}
