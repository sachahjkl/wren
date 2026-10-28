package browser

// The process queries the crash-recovery markers use (crash_recovery.odin): whether a recorded process id still runs and
// when it began, and this process's id. Windows asks the kernel; the Linux counterpart reads /proc.

import win "core:sys/windows"

current_pid :: proc() -> u32 { return u32(win.GetCurrentProcessId()) }

// Whether process `pid` runs, and when it began (FILETIME, 100 ns since 1601; 0 when the system would not say: another
// user's process).
process_created :: proc(pid: u32) -> (created: u64, alive: bool) {
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if h == nil { return 0, win.GetLastError() == win.ERROR_ACCESS_DENIED }
	defer win.CloseHandle(h)
	code: win.DWORD
	if !win.GetExitCodeProcess(h, &code) || code != 259 { return 0, false }   // STILL_ACTIVE
	c, e, k, u: win.FILETIME
	if !win.GetProcessTimes(h, &c, &e, &k, &u) { return 0, true }
	return u64(c.dwHighDateTime) << 32 | u64(c.dwLowDateTime), true
}
