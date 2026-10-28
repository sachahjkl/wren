package browser

// Moving a finished download's temporary file to its destination (download.odin's download_finish), on the blocking
// pool. The destination may be on another volume than the download folder (the Save dialog can send it anywhere), so
// Windows uses MoveFileExW with MOVEFILE_COPY_ALLOWED — identical to the path the shell used before it was made neutral.

import "core:fmt"
import win "core:sys/windows"

download_move :: proc(from, to: string) -> (ok: bool, why: string) {
	src := win.utf8_to_wstring(from, context.temp_allocator)
	dst := win.utf8_to_wstring(to, context.temp_allocator)
	if win.MoveFileExW(src, dst, win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_COPY_ALLOWED | win.MOVEFILE_WRITE_THROUGH) {
		return true, ""
	}
	return false, fmt.tprintf("error %d", win.GetLastError())
}
