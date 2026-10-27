package client

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"
import "wb:host"
import "wb:remote"

@(private = "file")
Exchange :: struct {
	name:   string,
	done:   bool,   // atomic
	ok:     bool,
	echoed: bool,
	err:    Call_Error,
	missing: Call_Error,
}

// What `wren ctl` does, end to end in one process: the client connects to the channel (a pipe on Windows, a Unix socket
// elsewhere) and gets the answer to its request, written by a handler on the loop's thread; an error answer comes back
// as one; a name nobody listens on is refused within its wait.
@(test)
a_call_goes_through_the_channel_and_back :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	name := fmt.tprintf("unit-chan-%d-%d", this_pid(), time.now()._nsec % 100000)
	handler :: proc(user: rawptr, conn: u64, line: []byte) {
		req, _, _ := remote.parse_request(line)
		if req.method == "Echo" {
			v, _ := remote.param_string(req.params, "text")
			remote.send(conn, remote.response_ok(req.id, fmt.tprintf(`{{"text":%s}}`, remote.quote(v))))
		} else {
			remote.send(conn, remote.response_error(req.id, remote.ERR_METHOD, "unknown method"))
		}
	}
	testing.expect_value(t, remote.start(&loop, name, 4096, 4, handler, nil, nil), "")
	ex := Exchange{name = name}
	worker := host.thread_start(proc(data: rawptr) {
		ex := (^Exchange)(data)
		c: Conn
		if connect(&c, ex.name, 2000) {
			r, e := call(&c, "Echo", `{"text":"héllo"}`, 5000)
			// (the answer is in this thread's temporary memory, gone with the thread: compared here)
			ex.ok, ex.echoed = e == .None, r.result == `{"text":"héllo"}`
			_, ex.err = call(&c, "Nope", "", 5000)
			disconnect(&c)
		}
		other: Conn
		if connect(&other, "unit-nobody-listens", 50) { disconnect(&other); ex.missing = .None } else { ex.missing = .No_Server }
		sync.atomic_store(&ex.done, true)
	}, &ex)
	deadline := time.tick_add(time.tick_now(), 30 * time.Second)
	for !sync.atomic_load(&ex.done) && time.tick_diff(time.tick_now(), deadline) > 0 { host.loop_wait(&loop, 20) }
	host.thread_join(worker)
	testing.expect(t, ex.ok, "the answer came")
	testing.expect(t, ex.echoed, "the answer is the handler's, byte for byte")
	testing.expect_value(t, ex.err, Call_Error.Server)
	testing.expect_value(t, ex.missing, Call_Error.No_Server)
	remote.stop()
	host.loop_drain(&loop)
}
