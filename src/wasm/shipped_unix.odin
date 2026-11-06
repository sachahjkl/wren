#+build !windows
package wasm

// (nothing: the pages of the program's file are the system's to reclaim, and a process's size does not count them apart)
@(private)
shipped_pages_drop :: proc(code: []byte) {}
