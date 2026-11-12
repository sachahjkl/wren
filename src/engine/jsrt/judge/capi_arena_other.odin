#+build !windows
package jsrt_judge

// Not on this system yet: `judge capi` then says that it cannot reserve memory below 4 GiB.
low_memory_reserve :: proc(addr: uintptr, size: uint) -> rawptr { return nil }
