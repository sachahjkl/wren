package idb

import "core:strings"
import win "core:sys/windows"

// Positional file access for the journals and checkpoints (Windows): a handle stays open for the life of an origin in
// memory and is read and written at explicit offsets (OVERLAPPED offsets on a synchronous handle), so a read of one value
// is a single call and never moves a file pointer. Opened with every share mode (including delete): a file that is
// replaced or removed while an old handle is still reading it just goes when the last handle closes.

File :: struct { h: win.HANDLE }

file_valid :: proc(f: File) -> bool { return f.h != nil && f.h != win.INVALID_HANDLE_VALUE }

@(private)
wide :: proc(s: string) -> win.LPCWSTR { return win.utf8_to_wstring(s, context.temp_allocator) }

// `create`: made when missing (read and write); else it must exist.
file_open :: proc(path: string, write: bool, create: bool) -> (f: File, ok: bool) {
	access: win.DWORD = win.GENERIC_READ
	if write { access |= win.GENERIC_WRITE }
	share: win.DWORD = win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE
	disp: win.DWORD = win.OPEN_ALWAYS if create else win.OPEN_EXISTING
	h := win.CreateFileW(wide(path), access, share, nil, disp, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return {}, false }
	return File{h}, true
}

file_close :: proc(f: ^File) {
	if file_valid(f^) { win.CloseHandle(f.h) }
	f^ = {}
}

file_size :: proc(f: File) -> (n: i64, ok: bool) {
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(f.h, &size) { return 0, false }
	return i64(size), true
}

// Reads exactly len(buf) bytes at `off`; false when the file is shorter or the read fails.
file_read_at :: proc(f: File, off: i64, buf: []byte) -> bool {
	at := 0
	for at < len(buf) {
		ov: win.OVERLAPPED
		o := u64(off) + u64(at)
		ov.Offset = win.DWORD(o & 0xFFFF_FFFF)
		ov.OffsetHigh = win.DWORD(o >> 32)
		n: win.DWORD
		chunk := win.DWORD(min(len(buf) - at, 1 << 30))
		if !win.ReadFile(f.h, raw_data(buf[at:]), chunk, &n, &ov) || n == 0 { return false }
		at += int(n)
	}
	return true
}

file_write_at :: proc(f: File, off: i64, data: []byte) -> bool {
	at := 0
	for at < len(data) {
		ov: win.OVERLAPPED
		o := u64(off) + u64(at)
		ov.Offset = win.DWORD(o & 0xFFFF_FFFF)
		ov.OffsetHigh = win.DWORD(o >> 32)
		n: win.DWORD
		chunk := win.DWORD(min(len(data) - at, 1 << 30))
		if !win.WriteFile(f.h, raw_data(data[at:]), chunk, &n, &ov) || n == 0 { return false }
		at += int(n)
	}
	return true
}

// Cuts (or extends) the file to `size`.
file_truncate :: proc(f: File, size: i64) -> bool {
	if !win.SetFilePointerEx(f.h, win.LARGE_INTEGER(size), nil, win.FILE_BEGIN) { return false }
	return bool(win.SetEndOfFile(f.h))
}

// Flushes what the system holds of the file to the disk.
file_sync :: proc(f: File) -> bool { return bool(win.FlushFileBuffers(f.h)) }

// A file replaced atomically (flushed through to the disk).
file_rename :: proc(from, to: string) -> bool {
	return bool(win.MoveFileExW(wide(from), wide(to), win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH))
}

file_delete :: proc(path: string) -> bool { return bool(win.DeleteFileW(wide(path))) }

file_exists :: proc(path: string) -> bool {
	a := win.GetFileAttributesW(wide(path))
	return a != win.INVALID_FILE_ATTRIBUTES && a & win.FILE_ATTRIBUTE_DIRECTORY == 0
}

// The names of the plain files of a directory that start with `prefix` (temporary memory).
dir_files_with_prefix :: proc(dir, prefix: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(wide(strings.concatenate({dir, "\\*"}, context.temp_allocator)), &fd)
	if h == win.INVALID_HANDLE_VALUE { return out[:] }
	defer win.FindClose(h)
	for {
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
			n := 0
			for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
			if name, err := win.utf16_to_utf8(fd.cFileName[:n], context.temp_allocator); err == nil && strings.has_prefix(name, prefix) {
				append(&out, name)
			}
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return out[:]
}
