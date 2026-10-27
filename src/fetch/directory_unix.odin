#+build linux, darwin, freebsd, openbsd, netbsd
package fetch

// The file: folders of directory.odin on POSIX: stat, realpath, readdir. Hidden entries are the dot files; names sort in
// natural order (file2 before file10), case-insensitively as Explorer's do on Windows; times are kept as FILETIME so the
// listing and its sort are the same code on every system.

import "core:fmt"
import "core:strings"
import "core:sys/posix"

// Seconds from 1601-01-01 (FILETIME's epoch) to 1970-01-01.
@(private)
FILETIME_UNIX_OFFSET :: 11_644_473_600

@(private)
filetime_of :: proc(ts: posix.timespec) -> u64 {
	s := i64(ts.tv_sec) + FILETIME_UNIX_OFFSET
	if s < 0 { return 0 }
	return u64(s) * 10_000_000 + u64(ts.tv_nsec) / 100
}

@(private)
file_status_of :: proc(err: posix.Errno) -> File_Status {
	#partial switch err {
	case .ENOENT, .ENOTDIR:     return .Not_Found
	case .EACCES, .EPERM:       return .Access_Denied
	case .ENAMETOOLONG, .ELOOP: return .Bad_Path
	}
	return .Failed
}

file_attributes :: proc(path: string) -> (File_Attributes, File_Status) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK { return {}, file_status_of(posix.errno()) }
	return {folder = posix.S_ISDIR(st.st_mode), size = i64(st.st_size), modified = filetime_of(st.st_mtim)}, .Ok
}

// The path a file or folder really is, symbolic links followed (realpath). False when it does not resolve.
final_path :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	r := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator))
	if r == nil { return "", false }
	defer posix.free(r)
	return strings.clone(string(r), allocator), true
}

// The entries of a folder, without "." and ".." (one fstatat each: readdir gives no size nor date).
read_directory :: proc(path: string, s: ^File_Settings, allocator := context.allocator) -> (l: Dir_Listing, st: File_Status) {
	context.allocator = allocator
	l.entries = make([dynamic]Dir_Entry)
	d := posix.opendir(strings.clone_to_cstring(path, context.temp_allocator))
	if d == nil { return l, file_status_of(posix.errno()) }
	defer posix.closedir(d)
	fd := posix.dirfd(d)
	limit := max(s.max_entries, 1)
	for {
		e := posix.readdir(d)
		if e == nil { break }
		name := string(cstring(&e.d_name[0]))
		if name == "." || name == ".." { continue }
		if strings.has_prefix(name, ".") && !s.show_hidden { l.hidden += 1; continue }
		l.found += 1
		if len(l.entries) >= limit { l.truncated = true; continue }
		ent := Dir_Entry{name = strings.clone(name)}
		lst: posix.stat_t
		if posix.fstatat(fd, cstring(&e.d_name[0]), &lst, {.SYMLINK_NOFOLLOW}) == .OK {
			ent.link = posix.S_ISLNK(lst.st_mode)
			target := lst
			// a link shows as what it points to (a folder link opens as a folder)
			if ent.link && posix.fstatat(fd, cstring(&e.d_name[0]), &target, {}) != .OK { target = lst }
			ent.folder = posix.S_ISDIR(target.st_mode)
			ent.size = i64(target.st_size)
			ent.modified = filetime_of(target.st_mtim)
		}
		append(&l.entries, ent)
	}
	return l, .Ok
}

// Natural order: case-insensitive, runs of digits compared as numbers (file2 < file10), then the bytes as a tie-break.
@(private)
name_cmp :: proc(a, b: Dir_Entry) -> i32 {
	x, y := a.name, b.name
	i, j := 0, 0
	lower :: proc(c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + 32 : c }
	digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
	for i < len(x) && j < len(y) {
		if digit(x[i]) && digit(y[j]) {
			// skip leading zeros, then the longer run is the larger number, else the first differing digit decides
			for i < len(x) && x[i] == '0' { i += 1 }
			for j < len(y) && y[j] == '0' { j += 1 }
			si, sj := i, j
			for i < len(x) && digit(x[i]) { i += 1 }
			for j < len(y) && digit(y[j]) { j += 1 }
			if i - si != j - sj { return i - si < j - sj ? -1 : 1 }
			if c := strings.compare(x[si:i], y[sj:j]); c != 0 { return i32(c) }
			continue
		}
		cx, cy := lower(x[i]), lower(y[j])
		if cx != cy { return cx < cy ? -1 : 1 }
		i += 1
		j += 1
	}
	if len(x) - i != len(y) - j { return len(x) - i < len(y) - j ? -1 : 1 }
	return i32(strings.compare(x, y))
}

// A FILETIME (UTC) as the local date and time: "2026-10-19 14:32".
local_time_text :: proc(ft: u64, allocator := context.temp_allocator) -> string {
	if ft == 0 { return "" }
	t := posix.time_t(i64(ft / 10_000_000) - FILETIME_UNIX_OFFSET)
	tm: posix.tm
	if posix.localtime_r(&t, &tm) == nil { return "" }
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, allocator = allocator)
}
