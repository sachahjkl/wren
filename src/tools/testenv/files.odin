package testenv

import "core:os"

// Deletes `path` and everything under it, file by file (core:os.remove_all goes through the shell's SHFileOperationW
// for a folder: not thread-safe, which tests running side by side are not, and it crashes a shell thread under
// AddressSanitizer, tools\asan.ps1). A junction or symbolic link is removed, never followed. The first error is
// returned; what could be deleted is.
remove_tree :: proc(path: string) -> (err: os.Error) {
	if path == "" { return nil }
	kind := path_kind(path)
	if kind == .Absent { return nil }   // gone already
	if kind != .Directory { return os.remove(path) }
	infos, rerr := os.read_all_directory_by_path(path, context.temp_allocator)
	if rerr != nil { return rerr }
	for fi in infos {
		if e := remove_tree(fi.fullpath); e != nil && err == nil { err = e }
	}
	if e := os.remove(path); e != nil && err == nil { err = e }
	return
}

// What a path names, links never followed: a junction or a symbolic link to a directory is a Link (files_<os>.odin).
Path_Kind :: enum { Absent, File, Directory, Link }
