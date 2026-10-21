package testenv

import "core:os"
import win "core:sys/windows"

// Deletes `path` and everything under it, file by file (core:os.remove_all goes through the shell's SHFileOperationW
// for a folder: not thread-safe, which tests running side by side are not, and it crashes a shell thread under
// AddressSanitizer, tools\asan.ps1). A junction or symbolic link is removed, never followed. The first error is
// returned; what could be deleted is.
remove_tree :: proc(path: string) -> (err: os.Error) {
	if path == "" { return nil }
	attrs := win.GetFileAttributesW(win.utf8_to_wstring(path, context.temp_allocator))
	if attrs == win.INVALID_FILE_ATTRIBUTES { return nil }   // gone already
	if attrs & win.FILE_ATTRIBUTE_DIRECTORY == 0 || attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return os.remove(path)
	}
	infos, rerr := os.read_all_directory_by_path(path, context.temp_allocator)
	if rerr != nil { return rerr }
	for fi in infos {
		if e := remove_tree(fi.fullpath); e != nil && err == nil { err = e }
	}
	if e := os.remove(path); e != nil && err == nil { err = e }
	return
}
