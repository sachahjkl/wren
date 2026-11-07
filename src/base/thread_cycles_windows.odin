#+build windows
package base

import win "core:sys/windows"

foreign import kernel32_cycles "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32_cycles {
	QueryThreadCycleTime :: proc(thread: win.HANDLE, cycles: ^u64) -> win.BOOL ---
}

// What the calling thread has spent on a processor, in the counter's cycles: exact at each read, where the system's CPU times move by its tick (15.6 ms, as much
// as a percent of a load). The counter runs at a fixed rate on the processors of today: a measure divides by the time stamp counter's frequency.
thread_cycles :: proc "contextless" () -> u64 {
	cycles: u64
	QueryThreadCycleTime(win.GetCurrentThread(), &cycles)
	return cycles
}
