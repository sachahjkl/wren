package desktop

import "core:strings"
import win "core:sys/windows"

System_Folder :: enum u8 {
	System,    // C:\Windows\System32 (cmd.exe, wevtutil.exe...)
	Windows,   // C:\Windows (explorer.exe)
}

// The full path of a program of the system. A program started by a bare name is looked for in the working directory (and
// in the executable's folder) before the system's: a folder someone else filled is enough to run what it holds with the
// user's rights. "" when Windows does not say where its folder is.
system_file :: proc(name: string, folder: System_Folder, allocator := context.temp_allocator) -> string {
	buf: [260]u16
	n := folder == .System ? win.GetSystemDirectoryW(&buf[0], len(buf)) : win.GetWindowsDirectoryW(&buf[0], len(buf))
	if n == 0 || int(n) >= len(buf) { return "" }
	dir, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "" }
	return strings.concatenate({strings.trim_right(dir, "\\/"), "\\", name}, allocator)
}