#+build !windows
package browser

// The heap and virtual-memory diagnostics of the memory-check driver (memcheck.odin's `vmmap` step) walk the Windows
// process heaps (HeapWalk) and committed regions (VirtualQuery), which have no portable equivalent. Off Windows they
// write a note saying so, so the endurance run's output is honest about what it could and could not read. The resident
// and private totals the driver's `stats` step reports do come from the system everywhere (base.process_counters).

import "core:os"

memory_heap_report :: proc(file: string, top := 40) {
	_ = top
	_ = os.write_entire_file(file, "heap report: not available on this platform (Windows HeapWalk only)\n")
}

memory_map_report :: proc(file: string, top := 40) {
	_ = top
	_ = os.write_entire_file(file, "vm map report: not available on this platform (Windows VirtualQuery only)\n")
}
