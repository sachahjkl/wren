package host

import "core:sys/posix"

// The main thread's stack, what /STACK:33554432 is on Windows. The kernel checks the limit when the stack grows, and leaves at least
// 128 MiB free below it whatever the limit was at exec, so raising it here is enough: no ulimit from whoever started Wren, no second exec.
main_stack_ensure :: proc() {
	WANT :: 32 * 1024 * 1024
	lim: posix.rlimit
	if posix.getrlimit(.STACK, &lim) != .OK { return }
	if lim.rlim_cur == posix.RLIM_INFINITY || lim.rlim_cur >= WANT { return }
	lim.rlim_cur = lim.rlim_max == posix.RLIM_INFINITY ? WANT : min(WANT, lim.rlim_max)
	posix.setrlimit(.STACK, &lim)
}
