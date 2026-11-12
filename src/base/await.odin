package base

import "core:sync"
import "core:time"

// Far beyond what any state of a test takes to be reached, even under AddressSanitizer on a loaded runner: a limit that
// only ends a failing run.
AWAIT_LIMIT :: 60 * time.Second
// How long the waiting thread sleeps between two looks at the state.
AWAIT_LOOK :: time.Millisecond

// A look at the state every AWAIT_LOOK, with the processor given back meanwhile. (A spin on thread.yield kept a whole processor
// for the wait: with a dozen test steps side by side, each spinning test slowed all the others.) The futex is the thread's own and
// nobody wakes it: its timeout is the pause. (Not in the generic procedure: a package that never instantiates it would leave
// core:sync unused.)
@(private = "file")
await_give_way :: proc() {
	pause: sync.Futex
	_ = sync.futex_wait_with_timeout(&pause, 0, AWAIT_LOOK)
}

// Test programs. Waits until `ready` says that the state another thread is reaching is there: a barrier on that state, where
// the code under test has no signal of its own. It looks again every AWAIT_LOOK, and its end is the state, not a time.
// False when the limit passed (the caller's check then fails).
await :: proc(data: ^$T, ready: proc(data: ^T) -> bool, limit := AWAIT_LIMIT) -> bool {
	start := time.tick_now()
	for !ready(data) {
		if time.tick_since(start) > limit { return false }
		await_give_way()
	}
	return true
}
