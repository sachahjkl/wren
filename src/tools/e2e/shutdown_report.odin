package e2e_scenarios

// A teardown that hangs ends the process, and says where first: on its standard error, what a test's log keeps, since the profile that holds the same text goes with the test.
// This program again, as a process that hangs: `wren ctl stacks` is what reads a process from outside, and this one answers that command too (src/e2e/e2e.odin).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "wb:e2e"
import "wb:host"
import "wb:crashtrace"

// Set: this process is the one that hangs, and it writes in this folder.
@(private = "file") HANG_FOLDER_VAR :: "WREN_TEST_TEARDOWN_HANG_FOLDER"
@(private = "file") HANG_STEP :: "the step that hangs"
@(private = "file") HANG_THREAD :: "test-hanging-thread"
// The watchdog speaks and ends the process at its first look.
@(private = "file") HANG_MS :: 1

@(private = "file")
teardown_that_hangs :: proc(folder: string) {
	never: sync.Sema
	crashtrace.set_report_dir(folder, "a test")
	crashtrace.begin_session()
	host.shutdown_on_force = crashtrace.end_session
	host.shutdown_begin(fmt.tprintf("%s/shutdown.log", folder), warn_ms = HANG_MS, force_ms = HANG_MS)
	host.shutdown_step(HANG_STEP)
	host.thread_join(host.thread_start(proc(data: rawptr) { sync.sema_wait((^sync.Sema)(data)) }, &never, name = HANG_THREAD))
}

@(test)
a_teardown_that_hangs_says_where_on_its_standard_error :: proc(t: ^testing.T) {
	if folder, hangs := os.lookup_env(HANG_FOLDER_VAR, context.temp_allocator); hangs {
		teardown_that_hangs(folder)
		return
	}
	program, err := os.get_executable_path(context.temp_allocator)
	testing.expect(t, err == nil)
	folder := e2e.temp_folder(t)
	r := e2e.run(t, {program, "-tests:a_teardown_that_hangs_says_where_on_its_standard_error"}, {env = {fmt.tprintf("%s=%s", HANG_FOLDER_VAR, folder)}})
	for said in ([]string{HANG_STEP, HANG_THREAD, "ending the process", "teardown_that_hangs", "thread_join"}) {
		testing.expectf(t, strings.contains(r.err, said), "it says %q: %s", said, r.err)
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/session.txt", folder)), "the watchdog ended it on purpose: the next start has no unclean exit to report")
}
