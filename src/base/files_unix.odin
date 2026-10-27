#+build linux, darwin, freebsd, openbsd, netbsd
package base

import "core:c/libc"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

@(private = "file")
cpath :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }

@(private = "file")
open_retry :: proc(path: string, flags: posix.O_Flags, mode := posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH}) -> posix.FD {
	for {
		fd := posix.open(cpath(path), flags + {.CLOEXEC}, mode)
		if fd >= 0 || posix.errno() != .EINTR { return fd }
	}
}

file_write_parts :: proc(path: string, parts: [][]byte, flush: bool) -> bool {
	fd := open_retry(path, {.WRONLY, .CREAT, .TRUNC})
	if fd < 0 { return false }
	ok := true
	for p in parts {
		at := 0
		for at < len(p) && ok {
			n := posix.write(fd, raw_data(p[at:]), uint(min(len(p) - at, 1 << 30)))
			if n < 0 && posix.errno() == .EINTR { continue }
			if n <= 0 { ok = false; break }
			at += int(n)
		}
	}
	if ok && flush { ok = posix.fsync(fd) == .OK }
	posix.close(fd)
	return ok
}

file_replace :: proc(from, to: string, durable: bool) -> bool {
	if libc.rename(cpath(from), cpath(to)) != 0 { return false }
	if durable { sync_dir(filepath.dir(to)) }
	return true
}

// A rename or a creation is on the disk once its directory is synced.
@(private = "file")
sync_dir :: proc(dir: string) {
	fd := open_retry(dir, {})
	if fd < 0 { return }
	posix.fsync(fd)
	posix.close(fd)
}

file_delete :: proc(path: string) -> bool {
	return posix.unlink(cpath(path)) == .OK || posix.errno() == .ENOENT
}

// The stamp is the modification time in nanoseconds since the Unix epoch.
file_stat :: proc(path: string) -> (size: i64, stamp: i64, ok: bool) {
	st: posix.stat_t
	if posix.stat(cpath(path), &st) != .OK || !posix.S_ISREG(st.st_mode) { return 0, 0, false }
	return i64(st.st_size), i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec), true
}

file_read_at :: proc(path: string, offset: i64, buf: []byte) -> (n: int, ok: bool) {
	fd := open_retry(path, {})
	if fd < 0 { return 0, false }
	defer posix.close(fd)
	for n < len(buf) {
		got := posix.pread(fd, raw_data(buf[n:]), uint(min(len(buf) - n, 1 << 30)), posix.off_t(offset + i64(n)))
		if got < 0 && posix.errno() == .EINTR { continue }
		if got < 0 { return n, false }
		if got == 0 { break }
		n += int(got)
	}
	return n, true
}

make_dirs :: proc(dir: string) { _ = os.make_directory_all(dir) }

list_files :: proc(dir: string, allocator := context.temp_allocator) -> []Dir_File {
	out := make([dynamic]Dir_File, allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return out[:] }
	for fi in infos {
		if fi.type != .Regular { continue }
		append(&out, Dir_File{name = strings.clone(fi.name, allocator), size = fi.size})
	}
	return out[:]
}
