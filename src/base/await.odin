package base

import "core:thread"
import "core:time"

// Far beyond what any state of a test takes to be reached, even under AddressSanitizer on a loaded runner: a limit that
// only ends a failing run.
AWAIT_LIMIT :: 60 * time.Second

// Test programs. Waits until `ready` says that the state another thread is reaching is there: a barrier on that state, where
// the code under test has no signal of its own. It gives its time slice away between looks and sleeps for no fixed time.
// False when the limit passed (the caller's check then fails).
await :: proc(data: ^$T, ready: proc(data: ^T) -> bool, limit := AWAIT_LIMIT) -> bool {
	start := time.tick_now()
	for !ready(data) {
		if time.tick_since(start) > limit { return false }
		thread.yield()
	}
	return true
}
