package desktop

import win "core:sys/windows"

foreign import shell32_args "system:Shell32.lib"

@(default_calling_convention = "system", private)
foreign shell32_args {
	CommandLineToArgvW :: proc(command_line: win.LPCWSTR, argc: ^win.c_int) -> [^]win.LPWSTR ---
}

// The program's arguments (without the program's own name) as UTF-8. Odin's os.args comes from the C runtime's narrow argv, in the
// system's ANSI code page: a path or a script with a letter outside it (an accent in a folder's name) arrives damaged. The
// command line itself is UTF-16.
command_line_args :: proc(allocator := context.temp_allocator) -> []string {
	argc: win.c_int
	argv := CommandLineToArgvW(win.GetCommandLineW(), &argc)
	if argv == nil || argc < 1 { return nil }
	defer win.LocalFree(rawptr(argv))
	out := make([]string, int(argc) - 1, allocator)
	for i in 1 ..< int(argc) {
		s, err := win.wstring_to_utf8(win.wstring(argv[i]), -1, allocator)
		out[i - 1] = err == nil ? s : ""
	}
	return out
}
