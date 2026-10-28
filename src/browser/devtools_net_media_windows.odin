package browser

// The system's media control interface for the developer-tools media preview (devtools_net_media.odin): formats the
// browser's own player cannot demux (MP3, WAV, WMA, ...) play through Windows' MCI from a temporary file. The Linux
// counterpart (devtools_net_media_other.odin) answers "unsupported".

import "core:strings"
import win "core:sys/windows"

foreign import winmm "system:winmm.lib"

@(default_calling_convention = "system", private = "file")
foreign winmm {
	mciSendStringW :: proc(command: win.LPCWSTR, ret: win.LPWSTR, ret_len: win.UINT, hwnd: win.HWND) -> win.DWORD ---
}

@(private)
mci :: proc(cmd: string) -> (result: string, ok: bool) {
	buf: [128]u16
	rc := mciSendStringW(win.utf8_to_wstring(cmd, context.temp_allocator), raw_data(buf[:]), len(buf), nil)
	s, _ := win.utf16_to_utf8(buf[:], context.temp_allocator)
	return strings.trim_right_null(s), rc == 0
}
