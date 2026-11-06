#+build windows
package e2e_scenarios

// `wren ctl stop <name>` ends the Wren that `wren ctl start` made, and nothing else (src\remote\client\spawn.odin, security review of 2026-10-25,
// finding 6). The session file keeps a pid; when the Wren has ended (closed by hand, crashed) and Windows has given the number to another program,
// `stop` used to wait 15 s for that program and then end it. It now checks the process it opened is the one written down (creation time and program)
// before it waits for it or ends it. This is about the command line itself, for the applications that use it: it stays what the test runs.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:e2e"
import "wb:remote/api"

// A program that stays and is nobody's: the system's ping, longer than the test.
@(private = "file") VICTIM_ECHOES :: "600"
// A creation time that is no process's.
@(private = "file") SOME_OTHER_TIME :: 133000000000000000

@(private = "file")
victim :: proc(t: ^testing.T) -> ^e2e.Program {
	root, _ := os.lookup_env("SystemRoot", context.temp_allocator)
	return e2e.program(t, {fmt.tprintf(`%s\System32\ping.exe`, root), "-n", VICTIM_ECHOES, "127.0.0.1"})
}

@(private = "file")
session_file :: proc(name: string) -> string { return fmt.tprintf(`%s\%s.json`, api.state_dir(), name) }

// A session file as `start` writes it, without what `who` leaves out.
@(private = "file")
write_session :: proc(name: string, pid: int, who: string) {
	_ = os.make_directory_all(api.state_dir())
	e2e.write_text(session_file(name), fmt.tprintf(`{{"name":%q,"pid":%d,%s"profile":"","temp":false}}`, name, pid, who))
}

@(private = "file")
stop_leaves_alone :: proc(t: ^testing.T, name: string, v: ^e2e.Program, loc := #caller_location) -> e2e.Run {
	r := e2e.run(t, {e2e.wren_exe(), "ctl", "stop", name}, loc = loc)
	testing.expectf(t, api.process_alive(&v.process), "%s: it is left alone: exit %d, %s", name, r.code, r.err, loc = loc)
	testing.expectf(t, !os.exists(session_file(name)), "%s: its session file is removed", name, loc = loc)
	return r
}

@(test)
stop_leaves_alone_a_pid_that_is_another_programs_now :: proc(t: ^testing.T) {
	name := fmt.tprintf("stale-%s", e2e.unique())

	// another creation time
	v := victim(t)
	write_session(name, v.pid, fmt.tprintf(`"created":%d,"image":%q,`, u64(SOME_OTHER_TIME), e2e.wren_exe()))
	began := time.tick_now()
	r := stop_leaves_alone(t, name, v)
	testing.expectf(t, time.duration_milliseconds(time.tick_since(began)) < api.CLOSE_WAIT_MS, "... at once: it was not waited for")
	testing.expectf(t, r.code == 0 && strings.contains(r.err, "left alone"), "... exit 0 and a word on stderr: %d, %q", r.code, r.err)

	// the same instant, another program
	who, _ := api.identity_of(&v.process)
	write_session(name, v.pid, fmt.tprintf(`"created":%d,"image":%q,`, who.created, e2e.wren_exe()))
	stop_leaves_alone(t, name, v)

	// a session file of an older wren ctl: it does not say who the process was
	write_session(name, v.pid, "")
	stop_leaves_alone(t, name, v)
}

@(test)
stop_ends_the_wren_it_started_and_its_throwaway_profile :: proc(t: ^testing.T) {
	started := e2e.run(t, {e2e.wren_exe(), "ctl", "start", "--headless", "--pref", "blocker.update.enabled=false"})
	name := strings.trim_space(started.out)
	testing.expectf(t, started.code == 0 && name != "", "start gives a name: %d, %q, %q", started.code, started.out, started.err)
	profile := fmt.tprintf(`%s\profile-%s`, api.state_dir(), name)
	s := api.Session{name = name, connect_wait_ms = e2e.PROCESS_WAIT_MS}
	ping, e := api.ping(&s)
	testing.expect_value(t, e, api.Error.None)
	api.close_session(&s)
	process, opened := api.process_open(ping.pid)
	testing.expect(t, opened)
	defer api.process_release(&process)
	who, _ := api.identity_of(&process)
	text := e2e.read_text(session_file(name))
	testing.expectf(t, who.created != 0 && strings.contains(text, fmt.tprintf(`"created":%d`, who.created)), "start writes who the process is: %s", text)
	stopped := e2e.run(t, {e2e.wren_exe(), "ctl", "stop", name})
	testing.expectf(t, stopped.code == 0, "stop: %d, %s", stopped.code, stopped.err)
	testing.expect(t, api.process_ended(&process), "stop ends the Wren it started")
	testing.expect(t, !os.exists(session_file(name)), "... and removes its session file")
	testing.expectf(t, !os.exists(profile), "... and its throwaway profile (%s): nothing stays, however long the system takes over the process", profile)
}
