package crashtrace

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"

// The helper the report runs is the system folder's, by its full path: never a bare name that CreateProcess would look up in the
// working directory first.
@(test)
system_tool_has_a_full_path :: proc(t: ^testing.T) {
	exe, line := system_tool_command(`C:\Windows\System32`, "wevtutil.exe", "qe Application /c:40")
	testing.expect_value(t, exe, `C:\Windows\System32\wevtutil.exe`)
	testing.expect_value(t, line, `"C:\Windows\System32\wevtutil.exe" qe Application /c:40`)
	exe, _ = system_tool_command(`C:\Windows\System32\`, "wevtutil.exe", "")
	testing.expect_value(t, exe, `C:\Windows\System32\wevtutil.exe`)
	exe, line = system_tool_command(`D:\Win dows\System32`, "wevtutil.exe", "x")
	testing.expect_value(t, exe, `D:\Win dows\System32\wevtutil.exe`)
	testing.expect(t, strings.has_prefix(line, `"D:\Win dows\`), "a path with a space is quoted")
}

// The fingerprint read from the image in memory is the one of the file on disk (what build.bat and the symbolizer read).
@(test)
fingerprint_is_the_files :: proc(t: ^testing.T) {
	buf: [32]u8
	fp := build_fingerprint(buf[:])
	testing.expect(t, len(fp) >= 9, fp)
	path: [520]u16
	n := win.GetModuleFileNameW(nil, &path[0], len(path))
	exe, _ := win.utf16_to_utf8(path[:n], context.temp_allocator)
	data, err := os.read_entire_file(exe, context.temp_allocator)
	testing.expect(t, err == nil, exe)
	stamp, size, ok := pe_stamp_and_size(uintptr(raw_data(data)))   // the headers are at the same offsets in the file
	testing.expect(t, ok)
	testing.expect_value(t, fp, fmt.tprintf("%08X%X", stamp, size))
	junk: [256]u8
	testing.expect_value(t, build_fingerprint(buf[:], uintptr(&junk[0])), "")   // not an image: nothing read past a bad "MZ"
}

@(test)
system_directory_is_the_systems :: proc(t: ^testing.T) {
	dir := system_directory()
	testing.expect(t, dir != "")
	testing.expect(t, strings.has_suffix(strings.to_lower(dir, context.temp_allocator), `\system32`), dir)
}
