package desktop

import win "core:sys/windows"

foreign import kernel32_ "system:Kernel32.lib"

@(default_calling_convention = "system", private)
foreign kernel32_ {
	AttachConsole :: proc(process_id: win.DWORD) -> win.BOOL ---
}

@(private = "file") ATTACH_PARENT_PROCESS :: win.DWORD(0xFFFF_FFFF)

@(private = "file") console_out: win.HANDLE   // the parent's console, once attached (CONOUT$)

// Writes `text` for the person or the script that ran the program: to the redirected standard output when there is
// one, else to the console of the process that started it. A Windows GUI program has neither at start-up.
console_write :: proc(text: string) {
	if text == "" { return }
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if h == nil || h == win.INVALID_HANDLE_VALUE {
		if console_out == nil {
			if !AttachConsole(ATTACH_PARENT_PROCESS) { return }
			console_out = win.CreateFileW(win.L("CONOUT$"), win.GENERIC_WRITE, win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
			if console_out == win.INVALID_HANDLE_VALUE { console_out = nil; return }
		}
		h = console_out
	}
	if win.GetFileType(h) == win.FILE_TYPE_CHAR {
		wide_text := win.utf8_to_utf16(text, context.temp_allocator)
		written: win.DWORD
		win.WriteConsoleW(h, raw_data(wide_text), win.DWORD(len(wide_text)), &written, nil)
		return
	}
	data := transmute([]byte)text
	for len(data) > 0 {
		written: win.DWORD
		if !win.WriteFile(h, raw_data(data), win.DWORD(len(data)), &written, nil) || written == 0 { return }
		data = data[written:]
	}
}
