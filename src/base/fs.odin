package base

import "base:runtime"
import "core:os"

// The directory for temporary files: TEMP when it is set (what tools\test_env.ps1 points at build\tmp, on every system),
// otherwise the system's (TMPDIR or /tmp on Unix, GetTempPathW on Windows). "" if there is none.
temp_dir :: proc(allocator := context.allocator) -> string {
	if t := os.get_env("TEMP", allocator); t != "" { return t }
	d, err := os.temp_directory(allocator)
	return err == nil ? d : ""
}

// Removes a file, or a directory with everything in it, one entry at a time (what a program does when it cleans up after itself:
// the test directories of the unit tests). os.remove_all asks the Windows shell (SHFileOperationW) to do it for a directory that
// is not empty, and the shell does not survive being called from a process under AddressSanitizer once other threads have run
// (the CI's unit tests of page ended there without a report). Absent: nothing to do. True when nothing is left.
remove_tree :: proc(path: string) -> bool {
	if path == "" { return true }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if os.is_dir(path) {
		entries, err := os.read_directory_by_path(path, -1, context.temp_allocator)
		if err == nil {
			for e in entries {
				if e.type == .Directory { remove_tree(e.fullpath) } else { os.remove(e.fullpath) }
			}
		}
	}
	err := os.remove(path)
	return err == nil || err == .Not_Exist
}