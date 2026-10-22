package host

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
shutdown_watchdog_names_what_waits :: proc(t: ^testing.T) {
	path := "build/shutdown_test.log"
	_ = os.make_directory_all("build")
	_ = os.remove(path)
	stop: b32
	th := thread_start(proc(data: rawptr) {
		for !sync.atomic_load((^b32)(data)) { time.sleep(5 * time.Millisecond) }
	}, &stop, name = "test-stuck-thread")
	testing.expect(t, th != nil)

	shutdown_begin(path, warn_ms = 300, force_ms = 0)
	shutdown_step("test step")
	time.sleep(900 * time.Millisecond)
	sync.atomic_store(&stop, true)
	thread_join(th)
	shutdown_end()

	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the log file was written")
	text := string(data)
	testing.expect(t, strings.contains(text, `step "test step"`), text)
	testing.expect(t, strings.contains(text, "test-stuck-thread"), text)
	testing.expect(t, strings.contains(text, "finished after"), text)
	_ = os.remove(path)
}
