package client

import "core:sys/posix"
import "core:testing"

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
