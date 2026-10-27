package base

import "core:strings"
import win "core:sys/windows"

@(private = "file")
wide :: proc(s: string) -> win.LPCWSTR { return win.utf8_to_wstring(s, context.temp_allocator) }

file_write_parts :: proc(path: string, parts: [][]byte, flush: bool) -> bool {
	h := win.CreateFileW(wide(path), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return false }
	ok := true
	for p in parts {
		at := 0
		for at < len(p) && ok {
			n: win.DWORD
			chunk := win.DWORD(min(len(p) - at, 1 << 30))
			if !win.WriteFile(h, raw_data(p[at:]), chunk, &n, nil) || n == 0 { ok = false; break }
			at += int(n)
		}
	}
	if ok && flush { ok = bool(win.FlushFileBuffers(h)) }
	win.CloseHandle(h)
	return ok
}

file_replace :: proc(from, to: string, durable: bool) -> bool {
	flags: win.DWORD = win.MOVEFILE_REPLACE_EXISTING
	if durable { flags |= win.MOVEFILE_WRITE_THROUGH }
	return bool(win.MoveFileExW(wide(from), wide(to), flags))
}

file_delete :: proc(path: string) -> bool {
	if win.DeleteFileW(wide(path)) { return true }
	e := win.GetLastError()
	return e == win.ERROR_FILE_NOT_FOUND || e == win.ERROR_PATH_NOT_FOUND
}

// The stamp is the last write time (FILETIME, 100 ns since 1601).
file_stat :: proc(path: string) -> (size: i64, stamp: i64, ok: bool) {
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(wide(path), win.GetFileExInfoStandard, &data) { return 0, 0, false }
	if data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 { return 0, 0, false }
	size = i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow)
	stamp = i64(data.ftLastWriteTime.dwHighDateTime) << 32 | i64(data.ftLastWriteTime.dwLowDateTime)
	return size, stamp, true
}

file_read_at :: proc(path: string, offset: i64, buf: []byte) -> (n: int, ok: bool) {
	h := win.CreateFileW(wide(path), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return 0, false }
	defer win.CloseHandle(h)
	for n < len(buf) {
		ov: win.OVERLAPPED
		o := u64(offset) + u64(n)
		ov.Offset = win.DWORD(o & 0xFFFF_FFFF)
		ov.OffsetHigh = win.DWORD(o >> 32)
		got: win.DWORD
		chunk := win.DWORD(min(len(buf) - n, 1 << 30))
		if !win.ReadFile(h, raw_data(buf[n:]), chunk, &got, &ov) {
			if win.GetLastError() == win.ERROR_HANDLE_EOF { break }
			return n, false
		}
		if got == 0 { break }
		n += int(got)
	}
	return n, true
}

make_dirs :: proc(dir: string) {
	// every level, from the root (CreateDirectory fails harmlessly on the ones that exist)
	for i in 0 ..< len(dir) {
		if (dir[i] == '\\' || dir[i] == '/') && i > 0 && dir[i - 1] != ':' { win.CreateDirectoryW(wide(dir[:i]), nil) }
	}
	win.CreateDirectoryW(wide(dir), nil)
}

list_files :: proc(dir: string, allocator := context.temp_allocator) -> []Dir_File {
	out := make([dynamic]Dir_File, allocator)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(wide(strings.concatenate({dir, "\\*"}, context.temp_allocator)), &fd)
	if h == win.INVALID_HANDLE_VALUE { return out[:] }
	defer win.FindClose(h)
	for {
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
			n := 0
			for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
			if name, err := win.utf16_to_utf8(fd.cFileName[:n], allocator); err == nil {
				append(&out, Dir_File{name = name, size = i64(fd.nFileSizeHigh) << 32 | i64(fd.nFileSizeLow)})
			}
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return out[:]
}
