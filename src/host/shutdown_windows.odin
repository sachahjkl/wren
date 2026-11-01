package host

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

// The process ends now, with this code: every thread and every library left as they are (no library is told to unload: Direct3D's driver takes
// 100 to 200 ms over that, for nothing). Whatever must reach a disk has been written before this.
process_end :: proc(code: int) -> ! {
	win.TerminateProcess(win.GetCurrentProcess(), win.UINT(code))
	win.ExitProcess(win.UINT(code))
}
