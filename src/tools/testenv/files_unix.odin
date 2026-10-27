#+build linux, darwin, freebsd, openbsd, netbsd
package testenv

import "core:strings"
import "core:sys/posix"

path_kind :: proc(path: string) -> Path_Kind {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK { return .Absent }
	if posix.S_ISLNK(st.st_mode) { return .Link }
	return posix.S_ISDIR(st.st_mode) ? .Directory : .File
}
