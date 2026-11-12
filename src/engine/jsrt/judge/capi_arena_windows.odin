package jsrt_judge

import win "core:sys/windows"

// Committed memory at `addr` (nil: the system put it elsewhere or refused): the C API's values hold 32-bit pointers.
low_memory_reserve :: proc(addr: uintptr, size: uint) -> rawptr {
	return win.VirtualAlloc(rawptr(addr), size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
}
