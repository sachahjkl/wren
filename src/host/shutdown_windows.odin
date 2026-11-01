package host

import "core:fmt"
import win "core:sys/windows"

@(private = "file")
ABOVE_NORMAL_PRIORITY_CLASS :: 0x00008000

foreign import kernel32_sd "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_sd {
	SetPriorityClass :: proc(process: win.HANDLE, priority_class: win.DWORD) -> win.BOOL ---
}

@(private)
shutdown_raise_priority :: proc() { SetPriorityClass(win.GetCurrentProcess(), ABOVE_NORMAL_PRIORITY_CLASS) }

@(private)
shutdown_force_exit :: proc() -> ! {
	win.ExitProcess(0)
}

// `program ctl stacks <this process> --out path`, waited for within `wait_ms`. At the priority of the process that ends: it is there to be
// read before it goes, whatever else the machine is doing.
@(private)
shutdown_read_stacks :: proc(program, path: string, wait_ms: int) {
	line := fmt.tprintf(`"%s" ctl stacks %d --out "%s"`, program, win.GetCurrentProcessId(), path)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, cstring16(win.utf8_to_wstring(line, context.temp_allocator)), nil, nil, false, win.CREATE_NO_WINDOW | ABOVE_NORMAL_PRIORITY_CLASS, nil, nil, &si, &pi) { return }
	win.CloseHandle(pi.hThread)
	win.WaitForSingleObject(pi.hProcess, win.DWORD(wait_ms))
	win.CloseHandle(pi.hProcess)
}

// The process ends now, with this code: every thread and every library left as they are (no library is told to unload: Direct3D's driver takes
// 100 to 200 ms over that, for nothing). Whatever must reach a disk has been written before this.
process_end :: proc(code: int) -> ! {
	win.TerminateProcess(win.GetCurrentProcess(), win.UINT(code))
	win.ExitProcess(win.UINT(code))
}
