package vault

import "core:os"
import "core:strings"
import win "core:sys/windows"

// Starts the helper with its stdin and stdout on our pipes, as os.process_start does, and CREATE_NO_WINDOW: wren-vault
// is a console program, and started from wren.exe, which has no console, Windows made one for it with a window (a
// terminal titled "wren-vault" opened beside the Vault's dialogs). Its stderr goes to NUL, as os.process_start's would.
@(private)
helper_start :: proc(path: string, stdin, stdout: ^os.File) -> (p: os.Process, err: os.Error) {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	null := win.CreateFileW(win.L("NUL"), win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	defer if null != win.INVALID_HANDLE_VALUE { win.CloseHandle(null) }
	program, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
	line := strings.concatenate({`"`, program, `"`}, context.temp_allocator)
	si := win.STARTUPINFOW{
		cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESTDHANDLES,
		hStdInput = win.HANDLE(os.fd(stdin)), hStdOutput = win.HANDLE(os.fd(stdout)),
		hStdError = null != win.INVALID_HANDLE_VALUE ? null : nil,
	}
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, cstring16(win.utf8_to_wstring(line, context.temp_allocator)), nil, nil, true,
		win.CREATE_NO_WINDOW | win.CREATE_UNICODE_ENVIRONMENT | win.NORMAL_PRIORITY_CLASS, nil, nil, &si, &pi) {
		return {}, os.Platform_Error(win.GetLastError())
	}
	win.CloseHandle(pi.hThread)
	return {pid = int(pi.dwProcessId), handle = uintptr(pi.hProcess)}, nil
}
