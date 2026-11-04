package host

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "wb:base"

@(private = "file") WATCHDOG_WARN_MS :: 1
@(private = "file") WATCHDOG_TICK :: time.Millisecond
// Rounds of two teardowns ending at the same moment.
@(private = "file") TEARDOWNS_AT_ONCE :: 50

@(test)
shutdown_watchdog_names_what_waits :: proc(t: ^testing.T) {
	path := "build/shutdown_test.log"
	_ = os.make_directory_all("build")
	_ = os.remove(path)
	stop: sync.Sema
	th := thread_start(proc(data: rawptr) { sync.sema_wait((^sync.Sema)(data)) }, &stop, name = "test-stuck-thread")
	testing.expect(t, th != nil)

	shutdown_begin(path, warn_ms = WATCHDOG_WARN_MS, force_ms = 0, tick = WATCHDOG_TICK)
	shutdown_step("test step")
	Nothing :: struct {}
	nothing: Nothing
	testing.expect(t, base.await(&nothing, proc(_: ^Nothing) -> bool { return shutdown_reports() > 0 }), "the watchdog reported")
	sync.sema_post(&stop)
	thread_join(th)
	shutdown_end()

	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the log file was written")
	text := string(data)
	testing.expect(t, strings.contains(text, `step "test step"`), text)
	testing.expect(t, strings.contains(text, "test-stuck-thread"), text)
	testing.expect(t, strings.contains(text, "finished after"), text)
	_ = os.remove(path)

	// Apps of the process that tear down at once share one watchdog, stopped and freed by the last of them: both ending
	// together joined it twice (the tracking allocator of the test says a second free)
	together: sync.Barrier
	for _ in 0 ..< TEARDOWNS_AT_ONCE {
		sync.barrier_init(&together, 2)
		other := thread_start(proc(data: rawptr) {
			shutdown_begin("", force_ms = 0, tick = WATCHDOG_TICK)
			sync.barrier_wait((^sync.Barrier)(data))
			shutdown_end()
		}, &together, name = "test-second-app")
		shutdown_begin("", force_ms = 0, tick = WATCHDOG_TICK)
		sync.barrier_wait(&together)
		shutdown_end()
		thread_join(other)
	}
	shutdown_end()   // (none under way: nothing happens)
}
