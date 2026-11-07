#+build windows
package base

import win "core:sys/windows"

// A file mapped read-only (the blocker's compiled index): its pages come from the file as they are read and go back to it under
// pressure, with nothing copied and no private memory. Delete is shared, so a newer generation can remove an older file in use.
File_Map :: struct {
	data:    []byte,
	file:    win.HANDLE,
	section: win.HANDLE,
}

file_map :: proc(path: string) -> (m: File_Map, ok: bool) {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	m.file = win.CreateFileW(wpath, win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if m.file == win.INVALID_HANDLE_VALUE { return {}, false }
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(m.file, &size) || size <= 0 || size > FILE_MAP_MOST { win.CloseHandle(m.file); return {}, false }
	m.section = win.CreateFileMappingW(m.file, nil, win.PAGE_READONLY, 0, 0, nil)
	if m.section == nil { win.CloseHandle(m.file); return {}, false }
	view := win.MapViewOfFile(m.section, win.FILE_MAP_READ, 0, 0, 0)
	if view == nil { win.CloseHandle(m.section); win.CloseHandle(m.file); return {}, false }
	m.data = ([^]byte)(view)[:int(size)]
	return m, true
}

file_unmap :: proc(m: ^File_Map) {
	if m.data != nil { win.UnmapViewOfFile(raw_data(m.data)) }
	if m.section != nil { win.CloseHandle(m.section) }
	if m.file != nil && m.file != win.INVALID_HANDLE_VALUE { win.CloseHandle(m.file) }
	m^ = {}
}
