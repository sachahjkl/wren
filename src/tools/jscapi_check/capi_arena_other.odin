#+build !windows
package jscapi_check

// Not on this system yet: `jscapi_check` then says that it cannot reserve memory below 4 GiB.
low_memory_reserve :: proc(addr: uintptr, size: uint) -> rawptr { return nil }
