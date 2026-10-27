package base

import win "core:sys/windows"

@(private)
native_process_memory :: proc() -> Process_Memory {
	c: win.PROCESS_MEMORY_COUNTERS_EX
	c.cb = size_of(c)
	if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), (^win.PROCESS_MEMORY_COUNTERS)(&c), size_of(c)) { return {} }
	return {resident = i64(c.WorkingSetSize), private = i64(c.PrivateUsage)}
}
