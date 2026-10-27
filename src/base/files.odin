package base

// Whole-file and positional file operations the stores share (the HTTP cache, the blocker's compiled lists), with the
// guarantees they rely on, on every system (files_<os>.odin):
//   file_write_parts   creates or truncates `path` and writes `parts` one after the other; `flush`: through to the disk
//   file_replace       renames `from` over `to` atomically (a reader sees the old file or the new one); `durable`: the
//                      new name is on the disk when it returns (MOVEFILE_WRITE_THROUGH; the directory synced on POSIX)
//   file_delete        removes a file (true when it is gone)
//   file_stat          size and the system's modification stamp (opaque: only compared with another stamp)
//   file_read_at       up to len(buf) bytes from `offset` (short at the end of the file). A file being replaced or
//                      deleted meanwhile is read as it was: readers never block a writer's rename or a deletion
//   make_dirs          the directory and every missing parent
//   list_files         the plain files of a directory (no subdirectory, no link to one), names and sizes

Dir_File :: struct {
	name: string,
	size: i64,
}

// The whole file, at most `max_size` bytes (false when it is larger, missing or unreadable).
file_read_all :: proc(path: string, allocator := context.allocator, max_size: i64 = 1 << 40) -> ([]byte, bool) {
	size, _, ok := file_stat(path)
	if !ok || size < 0 || size > max_size { return nil, false }
	buf := make([]byte, int(size), allocator)
	n, rok := file_read_at(path, 0, buf)
	if !rok || n != len(buf) { delete(buf, allocator); return nil, false }
	return buf, true
}

// Writes `data` to `path` through `path`.tmp renamed over it: a reader sees the old file or the new one.
file_write_atomic :: proc(path: string, data: []byte, flush := false) -> bool {
	tmp := concat_temp(path, ".tmp")
	parts := [1][]byte{data}
	if !file_write_parts(tmp, parts[:], flush) { file_delete(tmp); return false }
	if !file_replace(tmp, path, flush) { file_delete(tmp); return false }
	return true
}

@(private)
concat_temp :: proc(a, b: string) -> string {
	out := make([]byte, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}
