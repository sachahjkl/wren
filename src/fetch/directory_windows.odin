package fetch

// The file: folders of directory.odin on Win32: attributes, the final path of a link, FindFirstFile listings, Explorer's
// name order and the local time of a FILETIME.

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// A path Win32 accepts whatever its length: \\?\ (or \\?\UNC\) before a long one. The path is absolute and has no
// dot segments (it comes from a parsed URL).
win_path :: proc(path: string, allocator := context.temp_allocator) -> win.wstring {
	p := path
	if len(p) == 2 && p[1] == ':' { p = strings.concatenate({p, "\\"}, context.temp_allocator) }   // "C:" is the drive's current folder
	if len(p) >= 240 && !strings.has_prefix(p, `\\?\`) {
		p = strings.has_prefix(p, `\\`) ? strings.concatenate({`\\?\UNC\`, p[2:]}, context.temp_allocator) : strings.concatenate({`\\?\`, p}, context.temp_allocator)
	}
	return win.utf8_to_wstring(p, allocator)
}

@(private)
file_status_of :: proc(err: win.DWORD) -> File_Status {
	switch err {
	case win.ERROR_FILE_NOT_FOUND, win.ERROR_PATH_NOT_FOUND, 15 /* ERROR_INVALID_DRIVE */, 21 /* ERROR_NOT_READY */, 53 /* ERROR_BAD_NETPATH */, 67 /* ERROR_BAD_NET_NAME */:
		return .Not_Found
	case win.ERROR_ACCESS_DENIED, 32 /* ERROR_SHARING_VIOLATION */:
		return .Access_Denied
	case 123 /* ERROR_INVALID_NAME */, 161 /* ERROR_BAD_PATHNAME */, 206 /* ERROR_FILENAME_EXCED_RANGE */:
		return .Bad_Path
	}
	return .Failed
}

file_attributes :: proc(path: string) -> (File_Attributes, File_Status) {
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(win_path(path), win.GetFileExInfoStandard, &data) { return {}, file_status_of(win.GetLastError()) }
	return {
		folder = data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0,
		size = i64(u64(data.nFileSizeHigh) << 32 | u64(data.nFileSizeLow)),
		modified = u64(data.ftLastWriteTime.dwHighDateTime) << 32 | u64(data.ftLastWriteTime.dwLowDateTime),
	}, .Ok
}

// The path a file or folder really is, links and junctions followed (GetFinalPathNameByHandle), in the form of
// file_path_from_url (C:\... or \\server\share\...). False when it cannot be opened.
final_path :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	FILE_FLAG_BACKUP_SEMANTICS :: 0x0200_0000   // folders open too
	h := win.CreateFileW(win_path(path), 0, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == win.INVALID_HANDLE_VALUE { return "", false }
	defer win.CloseHandle(h)
	buf: [1024]u16
	n := win.GetFinalPathNameByHandleW(h, cstring16(&buf[0]), u32(len(buf)), win.VOLUME_NAME_DOS)
	if n == 0 || int(n) >= len(buf) { return "", false }
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "", false }
	switch {
	case strings.has_prefix(s, `\\?\UNC\`): s = strings.concatenate({`\\`, s[8:]}, context.temp_allocator)
	case strings.has_prefix(s, `\\?\`):     s = s[4:]
	}
	return strings.clone(s, allocator), true
}

// The entries of a folder (FindFirstFile: names, sizes and dates in one pass), without "." and "..".
read_directory :: proc(path: string, s: ^File_Settings, allocator := context.allocator) -> (l: Dir_Listing, st: File_Status) {
	context.allocator = allocator
	l.entries = make([dynamic]Dir_Entry)
	pattern := strings.concatenate({strings.trim_right(path, "\\/"), "\\*"}, context.temp_allocator)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(win_path(pattern), &fd)
	if h == win.INVALID_HANDLE_VALUE {
		err := win.GetLastError()
		if err == win.ERROR_FILE_NOT_FOUND { return l, .Ok }   // an empty drive: not even "." comes back
		return l, file_status_of(err)
	}
	defer win.FindClose(h)
	limit := max(s.max_entries, 1)
	for {
		n := 0
		for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
		w := fd.cFileName[:n]
		dots := (n == 1 && w[0] == '.') || (n == 2 && w[0] == '.' && w[1] == '.')
		if !dots {
			attrs := fd.dwFileAttributes
			if attrs & (win.FILE_ATTRIBUTE_HIDDEN | win.FILE_ATTRIBUTE_SYSTEM) != 0 && !s.show_hidden {
				l.hidden += 1
			} else {
				l.found += 1
				if len(l.entries) < limit {
					name, _ := win.utf16_to_utf8(w, allocator)
					wide := make([]u16, n + 1)
					copy(wide, w)
					append(&l.entries, Dir_Entry{
						name = name, wide = wide,
						folder = attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0,
						link = attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0,
						size = i64(u64(fd.nFileSizeHigh) << 32 | u64(fd.nFileSizeLow)),
						modified = u64(fd.ftLastWriteTime.dwHighDateTime) << 32 | u64(fd.ftLastWriteTime.dwLowDateTime),
					})
				} else {
					l.truncated = true
				}
			}
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return l, .Ok
}

foreign import shlwapi "system:Shlwapi.lib"
@(default_calling_convention = "system", private)
foreign shlwapi {
	StrCmpLogicalW :: proc(a, b: win.wstring) -> i32 ---
}

// Names compare as in Explorer: case-insensitive, digits as numbers (file2 < file10).
@(private)
name_cmp :: proc(a, b: Dir_Entry) -> i32 {
	if len(a.wide) == 0 || len(b.wide) == 0 { return i32(strings.compare(a.name, b.name)) }
	return StrCmpLogicalW(win.wstring(raw_data(a.wide)), win.wstring(raw_data(b.wide)))
}

// A FILETIME (UTC) as the local date and time: "2026-10-19 14:32".
local_time_text :: proc(ft: u64, allocator := context.temp_allocator) -> string {
	if ft == 0 { return "" }
	f := win.FILETIME{dwLowDateTime = win.DWORD(ft & 0xFFFF_FFFF), dwHighDateTime = win.DWORD(ft >> 32)}
	utc, loc: win.SYSTEMTIME
	if !win.FileTimeToSystemTime(&f, &utc) { return "" }
	if !win.SystemTimeToTzSpecificLocalTime(nil, &utc, &loc) { loc = utc }
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d", loc.year, loc.month, loc.day, loc.hour, loc.minute, allocator = allocator)
}
