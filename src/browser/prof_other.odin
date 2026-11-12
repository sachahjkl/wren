#+build !windows
#+vet !unused-imports
package browser

// The other systems' half of the frame measurement (prof.odin): the clock is core:time's tick, in nanoseconds. The
// profiler records the phases and the GPU; it has no sampler and no start-up times here.

import "core:strings"
import "core:time"

qpc :: proc "contextless" () -> i64 { return time.tick_now()._nsec }

qpc_frequency :: proc "contextless" () -> f64 { return 1e9 }

when PROFILE {

process_cpu :: proc() -> (user, kernel: u64) { return 0, 0 }
prof_sampling_start :: proc(app: ^App) {}
report_samples :: proc(sb: ^strings.Builder) {}
report_threads :: proc(sb: ^strings.Builder) {}
report_startup :: proc(sb: ^strings.Builder) {}

}
