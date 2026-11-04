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

foreign import ntdll_pt "system:ntdll.lib"

@(default_calling_convention = "system", private = "file")
foreign ntdll_pt {
	@(link_name = "NtGetNextThread") pt_NtGetNextThread :: proc(process, thread: win.HANDLE, access: u32, attributes, flags: u32, next: ^win.HANDLE) -> i32 ---
}

// What a thread handle of the walk may do: nothing is asked of it, the least the system grants.
@(private = "file") THREAD_QUERY_LIMITED_INFORMATION :: 0x0800
// NtGetNextThread past the last thread.
@(private = "file") STATUS_NO_MORE_ENTRIES :: i32(-2147483622)   // 0x8000001A

// Threads of this process, walked one by one (NtGetNextThread: each step a handle to the next thread of this process):
// -1 when the system will not say. Never a snapshot of the system's processes or threads: a snapshot copies every
// process of the machine, 20 to 45 ms on a busy one, where this walk costs microseconds per thread.
process_threads :: proc() -> int {
	self := win.GetCurrentProcess()
	at: win.HANDLE
	n := 0
	for {
		next: win.HANDLE
		status := pt_NtGetNextThread(self, at, THREAD_QUERY_LIMITED_INFORMATION, 0, 0, &next)
		if at != nil { win.CloseHandle(at) }
		if status == STATUS_NO_MORE_ENTRIES { return n }
		if status < 0 { return -1 }
		at = next
		n += 1
	}
}
