#+build !windows
package browser

// Moving a finished download's temporary file to its destination (download.odin's download_finish), on the blocking
// pool. A rename is atomic and durable (base.file_replace) when the two paths are on the same filesystem; the Save
// dialog can send the file to another volume, where rename fails (EXDEV on POSIX), so this falls back to a copy of the
// whole file followed by removing the temporary one — the counterpart of Windows' MOVEFILE_COPY_ALLOWED.

import "core:fmt"
import "core:os"
import "wb:base"

download_move :: proc(from, to: string) -> (ok: bool, why: string) {
	if base.file_replace(from, to, true) { return true, "" }
	// a different filesystem (or a destination directory a rename cannot reach): copy the bytes, then drop the source.
	data, rok := base.file_read_all(from)
	if !rok { return false, "cannot read the downloaded file" }
	defer delete(data)
	if !base.file_write_atomic(to, data, flush = true) { return false, fmt.tprintf("cannot write %s", to) }
	os.remove(from)
	return true, ""
}
