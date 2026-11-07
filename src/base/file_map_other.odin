#+build !windows
package base

import "core:strings"
import "core:sys/posix"

// A file mapped read-only (the blocker's compiled index): its pages come from the file as they are read, nothing is copied.
File_Map :: struct {
	data: []byte,
}

file_map :: proc(path: string) -> (m: File_Map, ok: bool) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {})
	if fd < 0 { return {}, false }
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size <= 0 || i64(st.st_size) > FILE_MAP_MOST { return {}, false }
	view := posix.mmap(nil, uint(st.st_size), {.READ}, {.PRIVATE}, fd, 0)
	if view == posix.MAP_FAILED { return {}, false }
	m.data = ([^]byte)(view)[:int(st.st_size)]
	return m, true
}

file_unmap :: proc(m: ^File_Map) {
	if m.data != nil { posix.munmap(raw_data(m.data), uint(len(m.data))) }
	m^ = {}
}
