package base

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Threads the test holds while it counts.
@(private = "file") HELD_THREADS :: 8
// Calls timed, the best one kept (a busy machine moves single calls).
@(private = "file") COUNT_TRIES :: 5
// What one count may cost: the process snapshot it replaced took 20 to 45 ms of a busy machine.
@(private = "file") COUNT_BUDGET :: 2 * time.Millisecond

@(test)
process_threads_counts_this_process_cheaply :: proc(t: ^testing.T) {
	before := process_threads()
	gate: sync.Sema
	held: [HELD_THREADS]^thread.Thread
	for &h in held {
		h = thread.create_and_start_with_data(&gate, proc(data: rawptr) { sync.sema_wait((^sync.Sema)(data)) })
	}
	during := process_threads()
	sync.sema_post(&gate, HELD_THREADS)
	for h in held { thread.join(h); thread.destroy(h) }
	after := process_threads()
	when ODIN_OS == .Windows || ODIN_OS == .Linux {
		testing.expect(t, before >= 1, "the test's own thread at least")
		testing.expectf(t, during - before >= HELD_THREADS, "the held threads counted: %d before, %d while held", before, during)
		testing.expectf(t, during - after >= HELD_THREADS, "and no longer once joined: %d while held, %d after", during, after)
		best := time.Duration(max(i64))
		for _ in 0 ..< COUNT_TRIES {
			t0 := time.tick_now()
			_ = process_threads()
			best = min(best, time.tick_since(t0))
		}
		testing.expectf(t, best < COUNT_BUDGET, "a count costs %v", best)
	}
}
