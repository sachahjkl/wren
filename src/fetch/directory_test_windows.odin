package fetch

import win "core:sys/windows"

// A hidden file of folder_listing: the attribute on Windows.
@(private)
HIDDEN_NAME :: "hidden.txt"

@(private)
mark_hidden :: proc(path: string) { win.SetFileAttributesW(win.utf8_to_wstring(path), win.FILE_ATTRIBUTE_HIDDEN) }
