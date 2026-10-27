package idb

import "core:path/filepath"
import "core:strings"

// Between a directory and a file name in the paths this package builds.
@(private)
SEP :: filepath.SEPARATOR_STRING

// Positional file access for the journals and checkpoints: File, file_open, file_read_at, file_write_at, file_truncate,
// file_sync, file_rename, file_delete, file_exists and dir_files_with_prefix are the system's (file_<os>.odin).

// Writes `parts` to a new file at `path` through a temporary file, flushed if asked, renamed over the old one.
file_replace_parts :: proc(path: string, parts: [][]byte, flush: bool) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	f, ok := file_open(tmp, true, true)
	if !ok { return false }
	good := file_truncate(f, 0)
	off: i64
	for p in parts {
		if !good { break }
		good = file_write_at(f, off, p)
		off += i64(len(p))
	}
	if good && flush { good = file_sync(f) }
	file_close(&f)
	if !good { file_delete(tmp); return false }
	if !file_rename(tmp, path) { file_delete(tmp); return false }
	return true
}
