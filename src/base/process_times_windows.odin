package base

// CPU and wall time of the running process, and its thread count, for the remote-control stats (src/browser's
// remote_state.odin: `wren ctl stats`, the wait for a quiet process). Windows reads the kernel; the neutral struct and
// the names are in process_times_other.odin for every other system (Linux reads /proc). Zero when the system cannot say.

import win "core:sys/windows"

Process_Times :: struct {
	user_ms, kernel_ms: f64,   // CPU time of all the process's threads
	uptime_ms:          f64,   // wall time since the process was created
}

@(private = "file")
ft_ms :: proc(f: win.FILETIME) -> f64 { return f64(u64(f.dwHighDateTime) << 32 | u64(f.dwLowDateTime)) / 10_000 }

@(private = "file")
ft_ticks :: proc(f: win.FILETIME) -> u64 { return u64(f.dwHighDateTime) << 32 | u64(f.dwLowDateTime) }

process_times :: proc() -> (t: Process_Times) {
	c, e, k, u: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	t.user_ms, t.kernel_ms = ft_ms(u), ft_ms(k)
	now: win.FILETIME
	win.GetSystemTimeAsFileTime(&now)
	t.uptime_ms = f64(ft_ticks(now) - ft_ticks(c)) / 10_000
	return
}

foreign import kernel32_pt "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_pt {
	@(link_name = "CreateToolhelp32Snapshot") pt_CreateToolhelp32Snapshot :: proc(flags: u32, pid: u32) -> win.HANDLE ---
	@(link_name = "Process32FirstW") pt_Process32FirstW :: proc(snap: win.HANDLE, e: ^win.PROCESSENTRY32W) -> win.BOOL ---
	@(link_name = "Process32NextW") pt_Process32NextW :: proc(snap: win.HANDLE, e: ^win.PROCESSENTRY32W) -> win.BOOL ---
}

@(private = "file") TH32CS_SNAPPROCESS :: 0x2

// Threads of this process, from the process's own entry of the process snapshot (each entry carries its thread count):
// -1 when the system will not say. Never the machine-wide thread list, which has thousands of entries on a busy runner.
process_threads :: proc() -> int {
	snap := pt_CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE { return -1 }
	defer win.CloseHandle(snap)
	e := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	pid := win.GetCurrentProcessId()
	ok := pt_Process32FirstW(snap, &e)
	for ok {
		if e.th32ProcessID == pid { return int(e.cntThreads) }
		e.dwSize = size_of(win.PROCESSENTRY32W)
		ok = pt_Process32NextW(snap, &e)
	}
	return -1
}
