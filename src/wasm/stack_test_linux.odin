package wasm

import "core:testing"

// Every call into a module asks where the stack ends: the system is asked once per thread (stack_linux.odin).
@(test)
a_thread_asks_for_its_stack_once :: proc(t: ^testing.T) {
	low := thread_stack_low()
	reads := stack_low_reads
	testing.expect(t, low != 0 && uintptr(&low) > low, "the stack ends under this frame")
	for _ in 0 ..< 3 { testing.expect_value(t, thread_stack_low(), low) }
	testing.expect_value(t, stack_low_reads, reads)
}
