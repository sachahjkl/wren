package api

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
a_child_is_waited_for_told_again_and_ended :: proc(t: ^testing.T) {
	p, pid, err := process_start({"/bin/sh", "-c", "exit 3"})
	testing.expect_value(t, err, "")
	testing.expect(t, pid > 0)
	testing.expect(t, process_wait(&p, 10_000), "a short child ends")
	testing.expect(t, posix.WIFEXITED(p.status) && posix.WEXITSTATUS(p.status) == 3, "its exit code is read")
	process_release(&p)

	_, _, bad := process_start({"/nonexistent/wren"})
	testing.expect(t, bad != "", "a program that does not exist is an error")

	s, spid, serr := process_start({"/bin/sh", "-c", "sleep 30"})
	testing.expect_value(t, serr, "")
	a, ok := identity_of(&s)
	testing.expect(t, ok && a.created != 0 && a.image != "", "a child's identity is read from /proc")
	o, opened := process_open(spid)
	testing.expect(t, opened)
	b, ok2 := identity_of(&o)
	testing.expect(t, ok2 && same_process(a, b), "the same process, told again by its pid")
	testing.expect(t, !same_process(a, {created = a.created + 1, image = a.image}), "a pid reused by a program started later")
	testing.expect(t, !same_process(a, {created = a.created, image = "/bin/other"}), "same instant, other program")
	testing.expect(t, !same_process({}, {}), "a record with nothing written names nobody")
	testing.expect(t, process_alive(&s))
	process_kill(&s)
	testing.expect(t, process_wait(&s, 10_000), "the child ends when killed")
	process_release(&s)
	process_release(&o)
	_, ended := wait_process_exit(spid, 1000)
	testing.expect(t, ended, "a process that ended is seen as ended")
}

// A child started with its outputs left out writes nowhere (as a program with no console does): it does not hold the
// caller's outputs, or `name=$(wren ctl start)` waits for the Wren it started to end.
@(test)
a_child_does_not_keep_the_callers_outputs :: proc(t: ^testing.T) {
	// (read from here, in /proc: a shell that looked at its own descriptors had them changed by its own redirection, dash
	// applying it to itself while the command runs)
	p, pid, err := process_start({"/bin/sh", "-c", "exec sleep 10"})
	testing.expect_value(t, err, "")
	defer process_release(&p)
	defer process_kill(&p)
	// the child set its descriptors once it runs sleep (the shell's exec): wait for that, at most 10 s
	deadline := time.tick_add(time.tick_now(), 10 * time.Second)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		cmd, _ := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", pid), context.temp_allocator)
		if strings.has_prefix(string(cmd), "sleep") { break }
		time.sleep(time.Millisecond)
	}
	for fd in 0 ..< 3 {
		target, rerr := os.read_link(fmt.tprintf("/proc/%d/fd/%d", pid, fd), context.temp_allocator)
		testing.expect(t, rerr == nil, "the child's descriptor can be read")
		testing.expectf(t, target == "/dev/null", "descriptor %d goes to %s", fd, target)
	}
}
