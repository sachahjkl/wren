#+build linux, darwin, freebsd, openbsd, netbsd
package idb

// Positional file access for the journals and checkpoints (POSIX): a descriptor stays open for the life of an origin in
// memory and is read and written with pread / pwrite, so a read of one value is a single call and never moves a file
// offset. A file that is replaced or removed while an old descriptor still reads it goes when the last one closes.

import "core:c/libc"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

File :: struct { fd: posix.FD, open: bool }

file_valid :: proc(f: File) -> bool { return f.open }

@(private)
cpath :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }

// `create`: made when missing (read and write); else it must exist.
file_open :: proc(path: string, write: bool, create: bool) -> (f: File, ok: bool) {
	flags := posix.O_Flags{.CLOEXEC}
	flags += write || create ? {.RDWR} : {}
	if create { flags += {.CREAT} }
	for {
		fd := posix.open(cpath(path), flags, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if fd >= 0 { return File{fd, true}, true }
		if posix.errno() != .EINTR { return {}, false }
	}
}

file_close :: proc(f: ^File) {
	if f.open { posix.close(f.fd) }
	f^ = {}
}

file_size :: proc(f: File) -> (n: i64, ok: bool) {
	st: posix.stat_t
	if posix.fstat(f.fd, &st) != .OK { return 0, false }
	return i64(st.st_size), true
}

// Reads exactly len(buf) bytes at `off`; false when the file is shorter or the read fails.
file_read_at :: proc(f: File, off: i64, buf: []byte) -> bool {
	at := 0
	for at < len(buf) {
		n := posix.pread(f.fd, raw_data(buf[at:]), uint(min(len(buf) - at, 1 << 30)), posix.off_t(off + i64(at)))
		if n < 0 && posix.errno() == .EINTR { continue }
		if n <= 0 { return false }
		at += int(n)
	}
	return true
}

file_write_at :: proc(f: File, off: i64, data: []byte) -> bool {
	at := 0
	for at < len(data) {
		n := posix.pwrite(f.fd, raw_data(data[at:]), uint(min(len(data) - at, 1 << 30)), posix.off_t(off + i64(at)))
		if n < 0 && posix.errno() == .EINTR { continue }
		if n <= 0 { return false }
		at += int(n)
	}
	return true
}

// Cuts (or extends) the file to `size`.
file_truncate :: proc(f: File, size: i64) -> bool { return posix.ftruncate(f.fd, posix.off_t(size)) == .OK }

// Flushes what the system holds of the file to the disk.
file_sync :: proc(f: File) -> bool { return posix.fsync(f.fd) == .OK }

// A file replaced atomically, and the directory entry made durable (what MOVEFILE_WRITE_THROUGH is on Windows): the
// directory is synced after the rename.
file_rename :: proc(from, to: string) -> bool {
	if libc.rename(cpath(from), cpath(to)) != 0 { return false }
	dir := filepath.dir(to)
	if fd := posix.open(cpath(dir), {.CLOEXEC}); fd >= 0 {
		posix.fsync(fd)
		posix.close(fd)
	}
	return true
}

file_delete :: proc(path: string) -> bool { return posix.unlink(cpath(path)) == .OK }

file_exists :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.stat(cpath(path), &st) == .OK && posix.S_ISREG(st.st_mode)
}

// The names of the plain files of a directory that start with `prefix` (temporary memory).
dir_files_with_prefix :: proc(dir, prefix: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return out[:] }
	for fi in infos {
		if fi.type == .Regular && strings.has_prefix(fi.name, prefix) { append(&out, fi.name) }
	}
	return out[:]
}
