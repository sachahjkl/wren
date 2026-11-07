package remote

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "wb:host"

// How long pump runs the loop for what a test expects, and the loop's wait each time (ms).
@(private = "file")
PUMP_DEADLINE :: 2 * time.Second
@(private = "file")
PUMP_WAIT_MS :: 20

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

// Runs the loop until `done` or PUMP_DEADLINE.
@(private = "file")
pump :: proc(loop: ^host.Loop, done: proc(s: ^Seen) -> bool, s: ^Seen) -> bool {
	deadline := time.tick_add(time.tick_now(), PUMP_DEADLINE)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		host.loop_wait(loop, PUMP_WAIT_MS)
		if done(s) { return true }
	}
	return false
}

@(private = "file")
unique_name :: proc(what: string) -> string {
	return fmt.tprintf("unit-%s-%d-%d", what, os.get_pid(), time.now()._nsec % 100000)
}

@(test)
a_request_gets_its_answer_through_the_loop :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	seen := Seen{reply = true}
	defer seen_destroy(&seen)
	name := unique_name("rt")
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, rawptr(&seen)), "")
	c := open_client(name)
	testing.expect(t, c != NO_CLIENT)
	testing.expect(t, write_text(c, "{\"id\":1,\"method\":\"x\"}\r\n\n{\"id\":2}\n"))
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return len(s.lines) >= 2 }, &seen))
	testing.expect_value(t, seen.lines[0], `{"id":1,"method":"x"}`)   // (the CR is not part of the line, the empty line is skipped)
	testing.expect_value(t, seen.lines[1], `{"id":2}`)
	testing.expect(t, strings.has_prefix(read_text(c), `{"id":1,"result":{"ok":true}}`))
	client_close(c)
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
	testing.expect_value(t, start(&loop, name, 1024, 4, on_line, on_gone, rawptr(&seen)), "")
	c := open_client(name)
	big, _ := strings.repeat("a", 3000, context.temp_allocator)
	write_text(c, big)
	reply := read_text(c)   // the error line, then the end
	testing.expect(t, strings.contains(reply, "max_message_bytes"))
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return len(s.closed) == 1 }, &seen))
	testing.expect_value(t, len(seen.lines), 0)
	client_close(c)
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
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, rawptr(&seen)), "")
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, rawptr(&seen)), "the remote channel is already running")   // (this process)
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
	testing.expect_value(t, start(&loop, name, 4096, 4, on_line, on_gone, rawptr(&seen)), "")
	c1 := open_client(name)
	c2 := open_client(name)
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return client_count() == 2 }, &seen))
	stop()   // joins the accept thread and both clients' threads, closes the pipes
	testing.expect(t, !running())
	client_close(c1); client_close(c2)
	host.loop_drain(&loop)
}

// The threads of the clients that have gone, held up as a loaded machine holds them: they are still counted, and the client after them is at the limit.
@(private = "file") HELD_CLIENTS :: 2
@(private = "file") held_started: int   // (atomic)
@(private = "file") held_release: sync.Sema

@(private = "file")
hold_first_clients :: proc() {
	if sync.atomic_add(&held_started, 1) < HELD_CLIENTS { sync.sema_wait(&held_release) }
}

@(test)
a_client_is_not_turned_away_by_clients_that_have_gone :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	seen := Seen{reply = true}
	defer seen_destroy(&seen)
	name := unique_name("gone")
	testing.expect_value(t, start(&loop, name, 4096, HELD_CLIENTS, on_line, on_gone, rawptr(&seen)), "")
	srv.client_hold = hold_first_clients
	gone: [HELD_CLIENTS]Test_Client
	for &c in gone { c = open_client(name) }
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return client_count() == HELD_CLIENTS }, &seen))
	for c in gone { client_close(c) }
	c := open_client(name)
	testing.expect(t, c != NO_CLIENT)
	write_text(c, "{\"id\":1}\n")
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return len(s.lines) == 1 }, &seen), "the client is served")
	testing.expect(t, strings.has_prefix(read_text(c), `{"id":1,"result":{"ok":true}}`))
	sync.sema_post(&held_release, HELD_CLIENTS)
	client_close(c)
	stop()
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
	testing.expect_value(t, start(&loop, name, 4096, 1, on_line, on_gone, rawptr(&seen)), "")
	c1 := open_client(name)
	testing.expect(t, pump(&loop, proc(s: ^Seen) -> bool { return client_count() == 1 }, &seen))
	c2 := open_client(name)   // connects (the next pipe instance, the listening socket), and is closed at once
	testing.expect(t, c2 != NO_CLIENT)
	testing.expect_value(t, read_text(c2), "")
	client_close(c2)
	stop()
	client_close(c1)
	host.loop_drain(&loop)
}
