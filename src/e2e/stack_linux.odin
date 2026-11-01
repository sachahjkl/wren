package e2e

import "core:os"
import "core:strings"
import "core:sys/posix"

// Linux: a test runs on a thread of the runner's, whose stack the C library sized from the limit it saw when the program started
// (no link option does it, as /STACK does on Windows). So the limit is raised and the program started again, once, at its very start.
@(private)
ensure_stack :: proc() {
	lim: posix.rlimit
	if posix.getrlimit(.STACK, &lim) != .OK { return }
	if lim.rlim_cur == posix.RLIM_INFINITY || lim.rlim_cur >= STACK_BYTES { return }
	if lim.rlim_max != posix.RLIM_INFINITY && lim.rlim_max < STACK_BYTES { return }
	lim.rlim_cur = STACK_BYTES
	if posix.setrlimit(.STACK, &lim) != .OK { return }
	argv := make([]cstring, len(os.args) + 1, context.temp_allocator)
	for a, i in os.args { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	posix.execv("/proc/self/exe", raw_data(argv))
}
