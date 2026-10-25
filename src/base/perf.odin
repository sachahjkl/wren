package base

import "core:fmt"
import "core:os"

// The one place that decides whether the tests that measure time run. A test that asserts on a duration, a CPU time, a throughput,
// a latency or a count of frames in a window of time depends on the machine, and the CI runners are of unknown speed: those tests
// are opt-in (tools\test_all.ps1 -Perf, or WREN_PERF=1 in the environment) and never run when the CI variable is set, whatever
// WREN_PERF says. A test that waits for something that must come, with a generous time limit that only ends a failing run, is not
// a performance test and does not ask.
//
//   if perf_skip("urlbar per-letter bounds") { return }   // prints "perf: skipped, run with -Perf: ..." and returns true
//   if !perf_enabled() { ... }                              // the same decision, no message

perf_decide :: proc(wren_perf, ci: string) -> bool {
	if ci != "" { return false }
	return wren_perf == "1" || wren_perf == "true"
}

perf_enabled :: proc() -> bool {
	return perf_decide(os.get_env("WREN_PERF", context.temp_allocator), os.get_env("CI", context.temp_allocator))
}

// True (after saying so) when the performance tests are off: the caller skips what measures time.
perf_skip :: proc(what: string) -> bool {
	if perf_enabled() { return false }
	if os.get_env("CI", context.temp_allocator) != "" {
		fmt.printfln("perf: skipped on the CI (the CI variable is set): %s", what)
	} else {
		fmt.printfln("perf: skipped, run with -Perf (tools\\test_all.ps1 -Perf, or WREN_PERF=1): %s", what)
	}
	return true
}
