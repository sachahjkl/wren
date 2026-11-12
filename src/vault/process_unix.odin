#+build linux, darwin, freebsd, openbsd, netbsd
package vault

import "core:sys/posix"

// The writer thread blocks SIGPIPE for itself: a write to a helper that died fails with EPIPE instead of ending the
// browser (the signal stays pending on this thread, which ends without taking it).
@(private)
writer_thread_signals :: proc() {
	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGPIPE)
	posix.pthread_sigmask(.BLOCK, &set, nil)
}
