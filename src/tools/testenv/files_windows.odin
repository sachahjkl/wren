package testenv

import win "core:sys/windows"

path_kind :: proc(path: string) -> Path_Kind {
	attrs := win.GetFileAttributesW(win.utf8_to_wstring(path, context.temp_allocator))
	if attrs == win.INVALID_FILE_ATTRIBUTES { return .Absent }
	if attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 { return .Link }
	return attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0 ? .Directory : .File
}
